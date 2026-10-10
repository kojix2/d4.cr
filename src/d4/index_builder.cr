require "json"

module D4
  # Builds embedded indexes by copying a local D4 to a temporary file in the
  # same directory, then publishing the fully indexed result on success.
  class IndexBuilder
    GRANULARITY = 65_536_i64

    def self.build(path : String | Path, *, track : String? = nil,
                   kinds : Array(IndexKind) = [IndexKind::SecondaryFrames, IndexKind::Sum]) : Nil
      raise ArgumentError.new("no index kinds requested") if kinds.empty?
      target = path.to_s
      temporary = ::File.tempfile(".d4-index-", ".tmp", dir: ::File.dirname(target))
      begin
        ::File.open(target, "rb") { |input| IO.copy(input, temporary) }
        temporary.close
        append(temporary.path, track: track, kinds: kinds)
        ::File.chmod(temporary.path, ::File.info(target).permissions)
        ::File.rename(temporary.path, target)
      ensure
        temporary.close unless temporary.closed?
        ::File.delete(temporary.path) if ::File.exists?(temporary.path)
      end
    end

    def self.append(path : String | Path, *, track : String? = nil,
                    kinds : Array(IndexKind) = [IndexKind::SecondaryFrames, IndexKind::Sum]) : Nil
      D4.open(path, track: track) do |file|
        selected = file.default_track
        root = Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
        directory = root
        selected.name.split('/').each do |component|
          next if component.empty?
          entry = directory.entry(component, 1_u8)
          directory = Format::Directory.open(file.source, entry.offset, file.options.max_metadata_bytes)
        end
        old_index = directory.entry?(".index")
        old_entries = if old_index
                        raise CorruptIndexError.new(".index is not a directory") unless old_index.directory?
                        Format::Directory.open(file.source, old_index.offset, file.options.max_metadata_bytes).entries
                      else
                        [] of Format::Entry
                      end
        ::File.open(path, "r+b") do |output|
          output.seek(0, IO::Seek::End)
          index_offset = output.pos.to_i64
          root_items = directory.entries.reject { |entry| entry.name == ".index" }.map do |entry|
            DirectoryEncoder::Item.new(entry.kind, entry.name, entry.offset, entry.size)
          end
          root_items << DirectoryEncoder::Item.new(1_u8, ".index", index_offset, Format::DIRECTORY_FRAME_SIZE.to_i64)
          raise UnsupportedFeatureError.new("track directory has no room for .index") unless DirectoryEncoder.build(directory.offset, root_items).size == Format::DIRECTORY_FRAME_SIZE

          output.write(Bytes.new(Format::DIRECTORY_FRAME_SIZE))
          index_items = old_entries.reject do |entry|
            (entry.name == "secondary_frame_index" && kinds.includes?(IndexKind::SecondaryFrames)) ||
              (entry.name == "sum_index" && kinds.includes?(IndexKind::Sum))
          end.map { |entry| DirectoryEncoder::Item.new(entry.kind, entry.name, entry.offset, entry.size) }

          if kinds.includes?(IndexKind::SecondaryFrames)
            offset = output.pos.to_i64
            write_sfi(file, directory, output)
            index_items << DirectoryEncoder::Item.new(2_u8, "secondary_frame_index", offset, output.pos.to_i64 - offset)
          end
          if kinds.includes?(IndexKind::Sum)
            offset = output.pos.to_i64
            write_sum(selected, output)
            index_items << DirectoryEncoder::Item.new(2_u8, "sum_index", offset, output.pos.to_i64 - offset)
          end
          index_directory = DirectoryEncoder.build(index_offset, index_items)
          raise UnsupportedFeatureError.new("index directory is too large") unless index_directory.size == Format::DIRECTORY_FRAME_SIZE
          index_end = output.pos.to_i64
          output.seek(index_offset, IO::Seek::Set)
          output.write(Format.bytes(index_directory))
          root_items[-1] = DirectoryEncoder::Item.new(1_u8, ".index", index_offset, index_end - index_offset)
          output.seek(directory.offset, IO::Seek::Set)
          output.write(Format.bytes(DirectoryEncoder.build(directory.offset, root_items)))
          output.flush
        end
      end
    end

    private def self.write_sfi(file : D4::File, directory : Format::Directory, output : IO) : Nil
      secondary = directory.entry(".stab", 1_u8)
      stab = Format::Directory.open(file.source, secondary.offset, file.options.max_metadata_bytes)
      metadata = stab.entry(".metadata", 0_u8)
      raw = Format::FrameStream.read(file.source, metadata.offset, metadata.size, file.options.max_metadata_bytes)
      info = JSON.parse(String.new(raw).rstrip('\0'))
      compression = info["compression"]?
      compressed = !(compression.nil? || compression.as_s? == "NoCompression")
      count_position = output.pos
      write_u64(output, 0_u64)
      count = 0_u64
      names = file.default_track.chromosomes.map(&.name)
      info["partitions"].as_a.each_with_index do |partition, part_index|
        name = partition[0].as_s
        chrom_id = names.index(name) || raise FormatError.new("secondary partition has unknown chromosome")
        stream = stab.entry(part_index.to_s, 0_u8)
        offset = stream.offset
        frame_size = stream.size
        first = true
        carry = Bytes.empty
        last_entry = nil.as(Int64?)
        frame_buffer = Bytes.empty
        loop do
          raise FormatError.new("invalid secondary frame size") if frame_size < 16 || frame_size > file.options.max_decoded_frame_bytes || frame_size > Int32::MAX
          frame_buffer = Bytes.new(frame_size.to_i) if frame_buffer.size < frame_size
          frame = frame_buffer[0, frame_size.to_i]
          file.source.read_exact_at(offset, frame)
          payload = frame[16, frame.size - 16]
          if compressed
            header = first ? 13 : 12
            raise FormatError.new("truncated compressed frame") if payload.size < header
            start_pos = Format::Endian.u32_le(payload, first ? 1 : 0)
            stop_pos = Format::Endian.u32_le(payload, first ? 5 : 4)
            skip = 0
          else
            start_pos, stop_pos, skip, carry, overhang = raw_span(payload, carry)
            if overhang
              raise UnsupportedFeatureError.new("index cannot address a frame containing only a partial record") unless last_entry
              end_position = output.pos
              output.seek(last_entry + 8, IO::Seek::Set)
              write_u32(output, overhang)
              output.seek(end_position, IO::Seek::Set)
            end
          end
          if stop_pos > start_pos
            last_entry = output.pos.to_i64
            write_sfi_entry(output, chrom_id.to_u32, start_pos, stop_pos, offset - stab.offset, frame_size, skip, first)
            count += 1
          end
          link = Format::Endian.i64_le(frame, 0)
          break if link == 0
          next_size = Format::Endian.u64_le(frame, 8)
          raise FormatError.new("invalid linked secondary frame") if link <= 0 || next_size > Int32::MAX || next_size < 16 || offset + link > file.source.size - next_size.to_i64
          offset += link
          frame_size = next_size.to_i64
          first = false
        end
        raise FormatError.new("truncated secondary record") unless carry.empty?
      end
      end_position = output.pos
      output.seek(count_position, IO::Seek::Set)
      write_u64(output, count)
      output.seek(end_position, IO::Seek::Set)
    end

    private def self.raw_span(payload : Bytes, carry : Bytes) : Tuple(UInt32, UInt32, Int32, Bytes, UInt32?)
      first = 0_u32
      last = 0_u32
      have_first = false
      cursor = 0
      overhang = nil.as(UInt32?)
      if !carry.empty?
        missing = 10 - carry.size
        raise FormatError.new("secondary record spans more than two frames") if payload.size < missing
        record = Bytes.new(10)
        record[0, carry.size].copy_from(carry)
        record[carry.size, missing].copy_from(payload[0, missing])
        encoded = Format::Endian.u32_le(record, 0)
        raise FormatError.new("invalid split secondary record") if encoded == 0
        overhang = encoded + Format::Endian.u16_le(record, 4)
        cursor = missing
      end
      skip = cursor
      while cursor + 10 <= payload.size
        encoded = Format::Endian.u32_le(payload, cursor)
        break if encoded == 0
        unless have_first
          first = encoded - 1
          have_first = true
        end
        last = encoded + Format::Endian.u16_le(payload, cursor + 4)
        cursor += 10
      end
      remaining = payload[cursor, payload.size - cursor]
      next_carry = if remaining.any? { |byte| byte != 0_u8 }
                     raise FormatError.new("invalid secondary record alignment") if remaining.size >= 10
                     remaining.dup
                   else
                     Bytes.empty
                   end
      {first, last, skip, next_carry, overhang}
    end

    private def self.write_sfi_entry(io : IO, chrom_id : UInt32, start_pos : UInt32, stop_pos : UInt32,
                                     offset : Int64, size : Int64, skip : Int32, first : Bool) : Nil
      io.write_byte(first ? 1_u8 : 0_u8)
      write_u32(io, chrom_id)
      write_u32(io, start_pos)
      write_u32(io, stop_pos)
      write_u64(io, offset.to_u64)
      write_u64(io, size.to_u64)
      io.write_byte(skip.to_u8)
    end

    private def self.write_sum(track : Track, output : IO) : Nil
      write_u32(output, GRANULARITY.to_u32)
      write_u32(output, 0_u32)
      scratch = Slice(Int32).new(65_536)
      track.chromosomes.each do |chromosome|
        position = 0_i64
        current_sum = 0_i64
        track.scan_values(Region.new(chromosome.name, 0, chromosome.size), scratch) do |_, values, count|
          count.times do |index|
            current_sum += values[index]
            position += 1
            if position % GRANULARITY == 0
              write_u64(output, current_sum.to_f64.unsafe_as(UInt64))
              current_sum = 0_i64
            end
          end
        end
        write_u64(output, current_sum.to_f64.unsafe_as(UInt64)) if position % GRANULARITY != 0
      end
    end

    private def self.write_u32(io : IO, value : UInt32) : Nil
      bytes = Bytes.new(4)
      4.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u32).to_u8 }
      io.write(bytes)
    end

    private def self.write_u64(io : IO, value : UInt64) : Nil
      bytes = Bytes.new(8)
      8.times { |index| bytes[index] = ((value >> (index * 8)) & 0xff_u64).to_u8 }
      io.write(bytes)
    end
  end

  def self.build_indexes(path : String | Path, *, track : String? = nil,
                         kinds : Array(IndexKind) = [IndexKind::SecondaryFrames, IndexKind::Sum]) : Nil
    IndexBuilder.build(path, track: track, kinds: kinds)
  end
end
