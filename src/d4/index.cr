module D4
  enum IndexKind
    SecondaryFrames
    Sum
  end

  enum IndexPolicy
    Auto
    Scan
    Require
  end

  class FrameAddress
    getter offset : Int64
    getter size : Int64
    getter record_offset : Int32
    getter first_frame : Bool
    getter start : Int64
    getter stop : Int64

    def initialize(@offset : Int64, @size : Int64, @record_offset : Int32, @first_frame : Bool,
                   @start : Int64 = 0_i64, @stop : Int64 = 0_i64); end
  end

  # On-disk binary search: the Rust packed entry is 30 bytes, not an array of
  # heap objects. Offsets in an SFI are relative to the secondary directory.
  class SecondaryFrameIndex
    ENTRY_SIZE = 30_i64
    @count : Int64
    @flag_first : Bool
    @chromosome_sizes : Array(Int64)

    def initialize(@source : Source, entry : Format::Entry, @secondary_base : Int64,
                   chromosomes : Array(Chromosome))
      raise CorruptIndexError.new("invalid SFI blob") unless entry.blob? && entry.size >= 8
      @offset = entry.offset + 8
      @chromosome_ids = Hash(String, Int32).new
      @chromosome_sizes = chromosomes.map(&.size)
      chromosomes.each_with_index { |chromosome, index| @chromosome_ids[chromosome.name] = index }
      header = Bytes.new(8)
      @source.read_exact_at(entry.offset, header)
      count = Format::Endian.u64_le(header, 0)
      raise CorruptIndexError.new("SFI size mismatch") unless count <= Int64::MAX // ENTRY_SIZE && entry.size == 8 + count.to_i64 * ENTRY_SIZE
      @count = count.to_i64
      @flag_first = false
      if @count > 0
        first = Bytes.new(ENTRY_SIZE.to_i)
        read_entry(0_i64, first)
        standard = valid_entry?(first, false)
        leading = valid_entry?(first, true)
        raise CorruptIndexError.new("invalid SFI entry layout") unless standard || leading
        @flag_first = leading && !standard
      end
    end

    def find(chromosome : String, position : Int64) : FrameAddress?
      chromosome_id = @chromosome_ids[chromosome]? || raise UnknownChromosomeError.new("unknown chromosome #{chromosome}")
      low = 0_i64
      high = @count
      scratch = Bytes.new(ENTRY_SIZE.to_i)
      shift = @flag_first ? 1 : 0
      while low < high
        middle = low + (high - low) // 2
        read_entry(middle, scratch)
        key_id = Format::Endian.u32_le(scratch, shift).to_i64
        key_pos = Format::Endian.u32_le(scratch, shift + 4).to_i64
        if key_id < chromosome_id || (key_id == chromosome_id && key_pos <= position)
          low = middle + 1
        else
          high = middle
        end
      end
      candidate = low > 0 ? low - 1 : low
      return nil if candidate >= @count
      read_entry(candidate, scratch)
      return nil unless Format::Endian.u32_le(scratch, shift) == chromosome_id
      # A record straddling a frame boundary can extend into the next frame.
      if candidate > 0 && Format::Endian.u32_le(scratch, shift + 4) <= position
        previous = Bytes.new(ENTRY_SIZE.to_i)
        read_entry(candidate - 1, previous)
        if Format::Endian.u32_le(previous, shift) == chromosome_id && Format::Endian.u32_le(previous, shift + 8) > position
          scratch = previous
        end
      end
      relative = Format::Endian.u64_le(scratch, shift + 12)
      size = Format::Endian.u64_le(scratch, shift + 20)
      skip = scratch[@flag_first ? 29 : 28].to_i
      flag = scratch[@flag_first ? 0 : 29]
      raise CorruptIndexError.new("invalid SFI address") if relative > Int64::MAX || size < Format::FRAME_HEADER_SIZE || size > Int32::MAX ||
                                                            @secondary_base > @source.size - relative.to_i64 || size > @source.size - @secondary_base - relative.to_i64 ||
                                                            skip >= 10 || flag > 1_u8
      FrameAddress.new(@secondary_base + relative.to_i64, size.to_i64, skip, flag == 1_u8,
        Format::Endian.u32_le(scratch, shift + 4).to_i64, Format::Endian.u32_le(scratch, shift + 8).to_i64)
    end

    private def read_entry(index : Int64, output : Bytes) : Nil
      @source.read_exact_at(@offset + index * ENTRY_SIZE, output)
    end

    private def valid_entry?(entry : Bytes, flag_first : Bool) : Bool
      shift = flag_first ? 1 : 0
      chrom = Format::Endian.u32_le(entry, shift)
      return false if chrom >= @chromosome_sizes.size
      start = Format::Endian.u32_le(entry, shift + 4)
      stop = Format::Endian.u32_le(entry, shift + 8)
      relative = Format::Endian.u64_le(entry, shift + 12)
      size = Format::Endian.u64_le(entry, shift + 20)
      start <= stop && stop <= @chromosome_sizes[chrom] &&
        relative <= Int64::MAX && @secondary_base <= @source.size - relative.to_i64 &&
        size >= Format::FRAME_HEADER_SIZE && size <= Int32::MAX &&
        size <= @source.size - @secondary_base - relative.to_i64 &&
        entry[flag_first ? 29 : 28] < 10_u8 && entry[flag_first ? 0 : 29] <= 1_u8
    end
  end

  class SumIndex
    MAX_CACHED_BYTES = 1_048_576_i64
    UNCACHED_SUM     = Int64::MIN

    getter granularity : Int64
    @offset : Int64
    @available_count : Int64
    @cached_values : Slice(Int64)?

    def initialize(@source : Source, entry : Format::Entry, chromosomes : Array(Chromosome))
      raise CorruptIndexError.new("invalid sum-index blob") unless entry.blob? && entry.size >= 4
      header = Bytes.new(4)
      @source.read_exact_at(entry.offset, header)
      @granularity = Format::Endian.u32_le(header, 0).to_i64
      raise CorruptIndexError.new("invalid sum-index header") unless @granularity > 0
      @chromosome_offsets = Hash(String, Int64).new
      count = 0_i64
      chromosomes.each do |chromosome|
        @chromosome_offsets[chromosome.name] = count
        count += (chromosome.size + @granularity - 1) // @granularity
      end
      raise CorruptIndexError.new("sum-index size mismatch") unless count <= (Int64::MAX - 8) // 8 &&
                                                                    (entry.size == 4 + count * 8 || entry.size == 8 + count * 8)
      # Rust's single-variant enum has zero size in the length calculation,
      # while the flexible-array payload is aligned to eight bytes. Its final
      # entry is therefore four bytes short; never read that incomplete bin.
      @offset = entry.offset + 8
      @available_count = (entry.size - 8) // 8
      @cached_values = nil
      @cache_mutex = Mutex.new
    end

    # Returns nil when the precision of every stored block cannot be proved.
    def full_blocks(chromosome : String, start : Int64, stop : Int64) : Int64?
      base = @chromosome_offsets[chromosome]? || raise UnknownChromosomeError.new("unknown chromosome #{chromosome}")
      first = (start + @granularity - 1) // @granularity
      last = stop // @granularity
      return 0_i64 if last <= first
      return nil if base + last > @available_count
      # Rust sums Int32 values into Float64. This bound makes each bin exact.
      return nil if @granularity > (1_i64 << 53) // (1_i64 << 31)
      raise ClosedError.new("source is closed") if @source.closed?
      # Keep at most 1 MiB of validated local bins; remote sources retain their
      # own consistency checks and larger indexes continue to stream.
      if @source.is_a?(LocalSource) && @available_count <= MAX_CACHED_BYTES // 8
        return @cache_mutex.synchronize { sum_cached(base + first, base + last) }
      end
      result = 0_i64
      # Read consecutive bins together. A chromosome-wide sum can span many
      # thousands of bins, and one seek/read per eight-byte entry dominates it.
      scratch = Bytes.new(Math.min(last - first, 8_192_i64).to_i * 8)
      index = first
      while index < last
        count = Math.min(last - index, 8_192_i64).to_i
        bytes = scratch[0, count * 8]
        @source.read_exact_at(@offset + (base + index) * 8, bytes)
        count.times do |bin|
          result += decode_sum(bytes, bin * 8)
        end
        index += count
      end
      result
    end

    private def sum_cached(first : Int64, last : Int64) : Int64
      values = @cached_values ||= Slice(Int64).new(@available_count.to_i, UNCACHED_SUM)
      scratch = Bytes.empty
      result = 0_i64
      index = first
      while index < last
        cached = values[index.to_i]
        if cached != UNCACHED_SUM
          result += cached
          index += 1
          next
        end
        count = 1
        limit = Math.min(last - index, 8_192_i64).to_i
        while count < limit && values[(index + count).to_i] == UNCACHED_SUM
          count += 1
        end
        scratch = Bytes.new(count * 8) if scratch.size < count * 8
        bytes = scratch[0, count * 8]
        @source.read_exact_at(@offset + index * 8, bytes)
        count.times do |bin|
          value = decode_sum(bytes, bin * 8)
          values[(index + bin).to_i] = value
          result += value
        end
        index += count
      end
      result
    end

    private def decode_sum(bytes : Bytes, offset : Int32) : Int64
      value = IO::ByteFormat::LittleEndian.decode(UInt64, bytes[offset, 8]).unsafe_as(Float64)
      raise CorruptIndexError.new("non-integral sum-index entry") unless value.finite? && value.abs <= (1_i64 << 53).to_f64
      integer = value.to_i64
      raise CorruptIndexError.new("non-integral sum-index entry") unless integer.to_f64 == value
      integer
    end
  end
end
