require "json"
require "compress/deflate"

module D4
  class RangeRecord
    getter left : Int64
    getter right : Int64
    getter value : Int32

    def initialize(@left : Int64, @right : Int64, @value : Int32); end

    def covers?(position : Int64) : Bool
      @left <= position && position < @right
    end
  end

  class Track
    @secondary : SecondaryTable?
    @owner : File?
    @sum_index : SumIndex?
    @sfi_index : SecondaryFrameIndex?

    getter name : String
    getter metadata : Metadata

    def initialize(@source : Source, @directory : Format::Directory, @name : String, @options : ReadOptions)
      @owner = nil
      metadata_entry = @directory.entry(".metadata", 0_u8)
      header_bytes = Format::FrameStream.read(@source, metadata_entry.offset, metadata_entry.size, @options.max_metadata_bytes)
      @metadata = HeaderParser.parse(header_bytes)
      index_root = if index_entry = @directory.entry?(".index")
                     raise CorruptIndexError.new(".index is not a directory") unless index_entry.directory?
                     Format::Directory.open(@source, index_entry.offset, @options.max_metadata_bytes)
                   end
      @sum_index = if entry = index_root.try(&.entry?("sum_index"))
                     SumIndex.new(@source, entry, @metadata.chromosomes)
                   end
      @sfi_index = nil
      if entry = index_root.try(&.entry?("secondary_frame_index"))
        secondary_entry = @directory.entry(".stab", 1_u8)
        @sfi_index = SecondaryFrameIndex.new(@source, entry, secondary_entry.offset, @metadata.chromosomes)
      end
      @primary = @directory.entry(".ptab", 2_u8)
      @chromosome_offsets = Hash(String, Int64).new
      offset = 0_i64
      @metadata.chromosomes.each do |chromosome|
        @chromosome_offsets[chromosome.name] = offset
        bits = chromosome.size * @metadata.dictionary.bit_width
        offset += (bits + 7) // 8
      end
      raise FormatError.new("primary table is shorter than its header declares") if offset > @primary.size
      @secondary = load_secondary
    end

    def bind_owner(owner : File) : Nil
      @owner = owner
    end

    def secondary_table : SecondaryTable?
      @secondary
    end

    def has_index?(kind : IndexKind) : Bool
      case kind
      in .secondary_frames? then !@sfi_index.nil?
      in .sum?              then !@sum_index.nil?
      end
    end

    def check_open : Nil
      raise ClosedError.new("D4 file is closed") if @owner.try(&.closed?) || @source.closed?
    end

    def chromosome(name : String) : Chromosome
      @metadata.chromosome(name)
    end

    def chromosome?(name : String) : Chromosome?
      @metadata.chromosome?(name)
    end

    def chromosomes : Array(Chromosome)
      @metadata.chromosomes
    end

    def chromosome_size(name : String) : Int64
      @metadata.chromosome_size(name)
    end

    def chromosome_size?(name : String) : Int64?
      @metadata.chromosome_size?(name)
    end

    def has_chromosome?(name : String) : Bool
      @metadata.has_chromosome?(name)
    end

    def value(chromosome : String, position : Int) : Int32
      raise ArgumentError.new("invalid point coordinate") if position < 0 || position.to_i64 >= chromosome_size(chromosome)
      check_open
      if @secondary.nil? || @secondary.not_nil!.empty?(chromosome)
        return primary_value(chromosome, position.to_i64)
      end
      region = checked_region(chromosome, position.to_i64, position.to_i64 + 1)
      result = 0_i32
      scan_values(region, Slice(Int32).new(1)) do |_start, values, count|
        result = values[0] if count == 1
      end
      result
    end

    private def primary_value(chromosome : String, position : Int64) : Int32
      dictionary = @metadata.dictionary
      width = dictionary.bit_width
      return dictionary.first_value if width == 0
      bit = position * width
      first_byte = bit // 8
      shift = (bit % 8).to_i
      bytes = Bytes.new((shift + width + 7) // 8)
      @source.read_exact_at(@primary.offset + @chromosome_offsets[chromosome] + first_byte, bytes)
      encoded = 0_u64
      bytes.each_with_index { |byte, index| encoded |= byte.to_u64 << (index * 8) }
      code = ((encoded >> shift) & ((1_u64 << width) - 1_u64)).to_u32
      dictionary.decode(code) || dictionary.first_value
    end

    def values(chromosome : String, start : Int = 0, stop : Int? = nil) : Array(Int32)
      check_open
      region = checked_region(chromosome, start.to_i64, stop.try(&.to_i64))
      bytes = region.length * sizeof(Int32)
      raise AllocationLimitError.new("values would allocate #{bytes} bytes") if region.length > Int32::MAX || bytes > @options.max_materialized_bytes
      output = Array(Int32).new(region.length.to_i, 0_i32)
      buffer = Slice(Int32).new(Math.min(region.length, 65_536_i64).to_i)
      cursor = 0
      scan_values(region, buffer) do |_block_start, values, count|
        count.times { |index| output[cursor + index] = values[index] }
        cursor += count
      end
      output
    end

    def values(region : Region) : Array(Int32)
      values(region.chromosome, region.start, region.stop)
    end

    def read_values_into(chromosome : String, start : Int, buffer : Slice(Int32)) : Int32
      check_open
      chrom = self.chromosome(chromosome)
      checked_region(chromosome, start.to_i64, start.to_i64) # Validate even for an empty buffer.
      return 0 if start.to_i64 == chrom.size || buffer.empty?
      region = checked_region(chromosome, start.to_i64, start.to_i64 + Math.min(chrom.size - start.to_i64, buffer.size))
      total = 0
      scan_values(region, buffer) { |_block_start, _values, count| total += count }
      total
    end

    def scan_values(chromosome : String, buffer : Slice(Int32), start : Int = 0, stop : Int? = nil, &block : Int64, Slice(Int32), Int32 -> Nil) : Nil
      scan_values(checked_region(chromosome, start.to_i64, stop.try(&.to_i64)), buffer) { |block_start, values, count| yield block_start, values, count }
    end

    def scan_values(region : Region, buffer : Slice(Int32), &block : Int64, Slice(Int32), Int32 -> Nil) : Nil
      check_open
      raise ArgumentError.new("scan buffer must not be empty") if buffer.empty?
      checked = checked_region(region.chromosome, region.start, region.stop)
      cursor = checked.start
      scanner = ValueScanner.new(self, checked, @secondary, buffer.size)
      while cursor < checked.stop
        count = Math.min(buffer.size.to_i64, checked.stop - cursor).to_i
        scanner.fill(buffer[0, count])
        yield cursor, buffer[0, count], count
        check_open
        cursor += count
      end
    end

    def each_value(chromosome : String, start : Int = 0, stop : Int? = nil, &block : Int32 -> Nil) : Nil
      scratch = Slice(Int32).new(65_536)
      scan_values(chromosome, scratch, start, stop) do |_offset, values, count|
        count.times { |index| yield values[index] }
      end
    end

    def each_value(chromosome : String, start : Int = 0, stop : Int? = nil)
      ValueIterator.new(self, checked_region(chromosome, start.to_i64, stop.try(&.to_i64)))
    end

    def each_interval(chromosome : String, start : Int = 0, stop : Int? = nil, &block : RawInterval -> Nil) : Nil
      region = checked_region(chromosome, start.to_i64, stop.try(&.to_i64))
      scratch = Slice(Int32).new(65_536)
      have_value = false
      interval_start = region.start
      previous = 0_i32
      scan_values(region, scratch) do |offset, values, count|
        count.times do |index|
          value = values[index]
          position = offset + index
          if have_value && value != previous
            yield RawInterval.new(interval_start, position, previous)
            interval_start = position
          end
          previous = value
          have_value = true
        end
      end
      yield RawInterval.new(interval_start, region.stop, previous) if have_value
    end

    def each_interval(chromosome : String, start : Int = 0, stop : Int? = nil)
      IntervalIterator.new(self, checked_region(chromosome, start.to_i64, stop.try(&.to_i64)))
    end

    def sum(chromosome : String, start : Int = 0, stop : Int? = nil, *, index : IndexPolicy = IndexPolicy::Auto) : Int64
      region = checked_region(chromosome, start.to_i64, stop.try(&.to_i64))
      return sum_scan(region) if index.scan?
      if stored = @sum_index
        granularity = stored.granularity
        first = (region.start + granularity - 1) // granularity * granularity
        last = region.stop // granularity * granularity
        return sum_scan(region) if first >= last
        if middle = stored.full_blocks(region.chromosome, region.start, region.stop)
          left = region.start < first ? sum_scan(Region.new(chromosome, region.start, first)) : 0_i64
          right = last < region.stop ? sum_scan(Region.new(chromosome, last, region.stop)) : 0_i64
          return left + middle + right
        end
        raise IndexPrecisionError.new("sum-index precision is insufficient") if index.require?
      elsif index.require?
        raise MissingIndexError.new("sum index is missing")
      end
      sum_scan(region)
    end

    private def sum_scan(region : Region) : Int64
      total = 0_i64
      scan_values(region, Slice(Int32).new(65_536)) do |_offset, values, count|
        count.times { |index| total += values[index] }
      end
      total
    end

    def sum(region : Region, *, index : IndexPolicy = IndexPolicy::Auto) : Int64
      sum(region.chromosome, region.start, region.stop, index: index)
    end

    def mean(chromosome : String, start : Int = 0, stop : Int? = nil, *, index : IndexPolicy = IndexPolicy::Auto) : Float64?
      region = checked_region(chromosome, start.to_i64, stop.try(&.to_i64))
      return nil if region.length == 0
      sum(region, index: index).to_f64 / region.length
    end

    def mean(region : Region, *, index : IndexPolicy = IndexPolicy::Auto) : Float64?
      mean(region.chromosome, region.start, region.stop, index: index)
    end

    def summary(chromosome : String, start : Int = 0, stop : Int? = nil) : Summary
      length = 0_i64
      sum = 0_i64
      min = nil.as(Int32?)
      max = nil.as(Int32?)
      scan_values(chromosome, Slice(Int32).new(65_536), start, stop) do |_offset, values, count|
        count.times do |index|
          value = values[index]
          length += 1
          sum += value
          min = value if min.nil? || value < min.not_nil!
          max = value if max.nil? || value > max.not_nil!
        end
      end
      Summary.new(length, sum, min, max)
    end

    def summary(region : Region) : Summary
      summary(region.chromosome, region.start, region.stop)
    end

    private def checked_region(chromosome : String, start : Int64, stop : Int64?) : Region
      chrom = self.chromosome(chromosome)
      actual_stop = stop || chrom.size
      if start < 0 || actual_stop < start || actual_stop > chrom.size
        raise ArgumentError.new("invalid region #{chromosome}:#{start}-#{actual_stop}")
      end
      Region.new(chromosome, start, actual_stop)
    end

    # Used by the reusable scanner; callers should normally use scan_values.
    def decode_primary(chromosome : String, start : Int64, output : Slice(Int32), packed : Bytes) : Nil
      dictionary = @metadata.dictionary
      width = dictionary.bit_width
      if width == 0
        output.fill(dictionary.first_value)
        return
      end
      first_bit = start * width
      last_bit = (start + output.size) * width
      first_byte = first_bit // 8
      last_byte = (last_bit + 7) // 8
      bytes = packed[0, (last_byte - first_byte).to_i]
      @source.read_exact_at(@primary.offset + @chromosome_offsets[chromosome] + first_byte, bytes)
      mask = (1_u64 << width) - 1_u64
      cursor = 1
      skip = (first_bit % 8).to_i
      accumulator = bytes[0].to_u64 >> skip
      available = 8 - skip
      if dictionary.type.simple_range?
        # A power-of-two range uses every code at this width, so no per-value bounds check is needed.
        low = dictionary.low.to_i64
        output.size.times do |index|
          while available < width
            accumulator |= bytes[cursor].to_u64 << available
            cursor += 1
            available += 8
          end
          output[index] = (low + (accumulator & mask).to_i64).to_i32
          accumulator >>= width
          available -= width
        end
      else
        first_value = dictionary.first_value
        output.size.times do |index|
          while available < width
            accumulator |= bytes[cursor].to_u64 << available
            cursor += 1
            available += 8
          end
          output[index] = dictionary.decode((accumulator & mask).to_u32) || first_value
          accumulator >>= width
          available -= width
        end
      end
    end

    private def load_secondary : SecondaryTable?
      entry = @directory.entry?(".stab")
      return nil unless entry && entry.directory?
      SecondaryTable.new(@source, Format::Directory.open(@source, entry.offset, @options.max_metadata_bytes), @options, @sfi_index)
    end
  end

  class ValueScanner
    @records : SecondaryRecordIterator?

    def initialize(@track : Track, @region : Region, secondary : SecondaryTable?, capacity : Int32)
      @position = @region.start
      @records = secondary.try(&.record_iterator(@region))
      @have_record = @records.try(&.next_fields) || false
      @packed = Bytes.new((capacity.to_i64 * @track.metadata.dictionary.bit_width + 14) // 8)
    end

    def fill(output : Slice(Int32)) : Int32
      @track.check_open
      count = Math.min(output.size.to_i64, @region.stop - @position).to_i
      return 0 if count == 0
      block = output[0, count]
      @track.decode_primary(@region.chromosome, @position, block, @packed)
      block_end = @position + count
      while @have_record
        records = @records.not_nil!
        break if records.left >= block_end
        left = Math.max(@position, records.left)
        right = Math.min(block_end, records.right)
        block[(left - @position).to_i, (right - left).to_i].fill(records.value) if right > left
        break if records.right > block_end
        @have_record = records.next_fields
      end
      @position = block_end
      count
    end
  end

  class ValueIterator
    include Iterator(Int32)

    def initialize(@track : Track, @region : Region)
      @scratch = Slice(Int32).new(65_536)
      @scanner = ValueScanner.new(@track, @region, @track.secondary_table, @scratch.size)
      @count = 0
      @index = 0
    end

    def next
      @track.check_open
      loop do
        if @index < @count
          value = @scratch[@index]
          @index += 1
          return value
        end
        count = @scanner.fill(@scratch)
        return stop if count == 0
        @count = count
        @index = 0
      end
    end
  end

  class IntervalIterator
    include Iterator(RawInterval)

    def initialize(@track : Track, @region : Region)
      @values = ValueIterator.new(@track, region)
      @position = region.start
      @pending = nil.as(Int32?)
    end

    def next
      @track.check_open
      return stop if @position >= @region.stop
      first = @pending
      first = @values.next if first.nil?
      return stop if first.is_a?(Iterator::Stop)
      left = @position
      @pending = nil
      @position += 1
      while @position < @region.stop
        value = @values.next
        break if value.is_a?(Iterator::Stop)
        if value != first
          @pending = value
          break
        end
        @position += 1
      end
      RawInterval.new(left, @position, first)
    end
  end

  class SecondaryTable
    def initialize(@source : Source, @directory : Format::Directory, @options : ReadOptions,
                   @index : SecondaryFrameIndex?)
      @empty_mutex = Mutex.new
      @empty_chromosomes = Hash(String, Bool).new
      metadata = @directory.entry(".metadata", 0_u8)
      data = Format::FrameStream.read(@source, metadata.offset, metadata.size, @options.max_metadata_bytes)
      json = JSON.parse(trim_nuls(data))
      raise UnsupportedFeatureError.new("unsupported secondary record format") unless json["record_format"].as_s == "range"
      compression = json["compression"]?
      @compressed = if compression.nil? || compression.as_s? == "NoCompression"
                      false
                    elsif compression["Deflate"]?
                      true
                    else
                      raise UnsupportedFeatureError.new("unsupported D4 secondary compression")
                    end
      @partitions = Hash(String, Array(Format::Entry)).new { |hash, key| hash[key] = Array(Format::Entry).new }
      json["partitions"].as_a.each_with_index do |partition, index|
        parts = partition.as_a
        raise FormatError.new("invalid secondary partition") unless parts.size >= 3 && parts[1].as_i64 >= 0 && parts[2].as_i64 >= parts[1].as_i64
        @partitions[parts[0].as_s] << @directory.entry(index.to_s, 0_u8)
      end
    end

    def record_iterator(region : Region) : SecondaryRecordIterator
      SecondaryRecordIterator.new(@source, @partitions[region.chromosome]? || Array(Format::Entry).new,
        @compressed, region, @options.max_decoded_frame_bytes, @index.try(&.find(region.chromosome, region.start)))
    end

    def empty?(chromosome : String) : Bool
      @empty_mutex.synchronize do
        @empty_chromosomes.fetch(chromosome) do
          entries = @partitions[chromosome]?
          @empty_chromosomes[chromosome] = entries.nil? || entries.all? { |entry| empty_stream?(entry) }
        end
      end
    end

    private def empty_stream?(entry : Format::Entry) : Bool
      return true if !@compressed && entry.size == Format::FRAME_HEADER_SIZE
      header_size = @compressed ? 29 : 20
      return false if entry.size < header_size
      header = Bytes.new(header_size)
      @source.read_exact_at(entry.offset, header)
      return false unless Format::Endian.u64_le(header, 0) == 0_u64
      if @compressed
        Format::Endian.u32_le(header, 25) == 0_u32
      else
        Format::Endian.u32_le(header, 16) == 0_u32
      end
    end

    private def trim_nuls(bytes : Bytes) : String
      end_at = bytes.size
      while end_at > 0 && bytes[end_at - 1] == 0_u8
        end_at -= 1
      end
      String.new(bytes[0, end_at])
    end
  end

  class SecondaryRecordIterator
    getter left : Int64
    getter right : Int64
    getter value : Int32

    def initialize(@source : Source, @entries : Array(Format::Entry), @compressed : Bool,
                   @region : Region, @max_bytes : Int64, address : FrameAddress? = nil)
      @entry_index = 0
      @stream = nil.as(Format::FrameStream?)
      @payload = Bytes.empty
      @cursor = 0
      @first_frame = address.try(&.first_frame) != false
      @skip_bytes = address.try(&.record_offset) || 0
      @stream = Format::FrameStream.new(@source, address.offset, address.size, Int64::MAX, @max_bytes) if address
      @entry_index = @entries.size if address
      @records_left = 0_i64
      @record = Bytes.new(10)
      @decoded = Bytes.empty
      @extra = Bytes.new(1)
      @last_right = 0_i64
      @left = 0_i64
      @right = 0_i64
      @value = 0_i32
    end

    def next_record : RangeRecord?
      return nil unless next_fields
      RangeRecord.new(@left, @right, @value)
    end

    def next_fields : Bool
      loop do
        if @stream.nil?
          return false if @entry_index >= @entries.size
          entry = @entries[@entry_index]
          @entry_index += 1
          @stream = Format::FrameStream.new(@source, entry.offset, entry.size, Int64::MAX, @max_bytes)
          @payload = Bytes.empty
          @cursor = 0
          @first_frame = true
        end
        if @compressed
          if @records_left == 0
            unless load_compressed_frame
              @stream = nil
              next
            end
          end
          record = @payload[@cursor, 10]
          @cursor += 10
          @records_left -= 1
        else
          unless record = read_raw_record
            @stream = nil
            next
          end
        end
        encoded = Format::Endian.u32_le(record, 0)
        if encoded == 0
          raise FormatError.new("invalid compressed secondary record") if @compressed
          @stream = nil
          next
        end
        left = encoded.to_i64 - 1
        right = encoded.to_i64 + Format::Endian.u16_le(record, 4)
        raise FormatError.new("secondary records overlap or are unsorted") if left < @last_right
        @last_right = right
        return false if left >= @region.stop
        next if right <= @region.start
        @left = left
        @right = right
        @value = Format::Endian.u32_le(record, 6).unsafe_as(Int32)
        return true
      end
    end

    private def read_raw_record : Bytes?
      if @cursor + 10 <= @payload.size
        record = @payload[@cursor, 10]
        @cursor += 10
        return record
      end
      filled = 0
      while filled < 10
        if @cursor >= @payload.size
          frame = @stream.not_nil!.next_payload
          if frame.nil?
            raise FormatError.new("truncated secondary record") if filled > 0
            return nil
          end
          @payload = frame
          @cursor = @skip_bytes
          @skip_bytes = 0
          next
        end
        count = Math.min(10 - filled, @payload.size - @cursor)
        @record[filled, count].copy_from(@payload[@cursor, count])
        @cursor += count
        filled += count
      end
      @record
    end

    private def load_compressed_frame : Bool
      frame = @stream.not_nil!.next_payload
      return false unless frame
      header = @first_frame ? 13 : 12
      raise FormatError.new("truncated compressed secondary frame") if frame.size < header
      raw = @first_frame && frame[0] == 1_u8
      raise FormatError.new("invalid compressed frame marker") if @first_frame && frame[0] > 1_u8
      count = Format::Endian.u32_le(frame, header - 4).to_i64
      raise AllocationLimitError.new("decoded secondary frame exceeds configured limit") if count * 10 > @max_bytes || count * 10 > Int32::MAX
      encoded = frame[header, frame.size - header]
      if raw
        raise FormatError.new("raw secondary frame length mismatch") if encoded.size < count * 10
        @payload = encoded[0, (count * 10).to_i]
      else
        size = (count * 10).to_i
        @decoded = Bytes.new(size) if @decoded.size < size
        output = @decoded[0, size]
        Compress::Deflate::Reader.open(IO::Memory.new(encoded)) do |reader|
          begin
            reader.read_fully(output)
          rescue IO::EOFError
            raise FormatError.new("truncated compressed secondary frame")
          end
          raise FormatError.new("compressed secondary frame has extra data") unless reader.read(@extra) == 0
        end
        @payload = output
      end
      @cursor = 0
      @records_left = count
      @first_frame = false
      true
    rescue error : Compress::Deflate::Error
      raise FormatError.new("invalid compressed secondary frame: #{error.message}")
    end
  end

  module HeaderParser
    def self.parse(data : Bytes) : Metadata
      end_at = data.size
      while end_at > 0 && data[end_at - 1] == 0_u8
        end_at -= 1
      end
      json = JSON.parse(String.new(data[0, end_at]))
      chromosomes = json["chrom_list"].as_a.map do |chromosome|
        Chromosome.new(chromosome["name"].as_s, chromosome["size"].as_i64)
      end
      dictionary_value = json["dictionary"]
      dictionary = if simple = dictionary_value["SimpleRange"]?
                     Dictionary.new(simple["low"].as_i.to_i32, simple["high"].as_i.to_i32)
                   elsif mapping = dictionary_value["Dictionary"]?
                     Dictionary.new(mapping["i2v_map"].as_a.map { |value| value.as_i.to_i32 })
                   else
                     raise FormatError.new("unsupported D4 dictionary")
                   end
      denominator_value = json["denominator"]?
      denominator = if denominator_value && denominator_value.as_s? != "One"
                      denominator_value["Value"].as_f
                    else
                      1.0
                    end
      Metadata.new(chromosomes, dictionary, denominator)
    rescue error : JSON::ParseException
      raise FormatError.new("invalid D4 metadata JSON: #{error.message}")
    end
  end
end
