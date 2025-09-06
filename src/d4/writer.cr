require "./file"

module D4
  class File
    # Set chromosomes for a new D4 file (write mode)
    def set_chromosomes(chromosomes : Hash(String, UInt32), dict_type : DictType = DictType::SimpleRange, denominator : Float64 = 1.0)
      check_not_closed
      # Prepare chromosome data (copy to deterministic arrays)
      chrom_names = chromosomes.keys.to_a
      chrom_sizes = chromosomes.values.to_a

      name_count = chrom_names.size

      # Allocate C arrays (char** for names, UInt32* for sizes)
      name_array = LibC.malloc(name_count * sizeof(Pointer(LibC::Char))).as(LibC::Char**)
      size_array = LibC.malloc(name_count * sizeof(UInt32)).as(UInt32*)

      allocated_strings = Array(LibC::Char*).new(name_count)

      begin
        name_count.times do |i|
          s = chrom_names[i]
          bytesize = s.bytesize
          cstr = LibC.malloc(bytesize + 1).as(LibC::Char*)
          # copy bytes
          s.to_slice.copy_to(Slice.new(cstr, bytesize))
          cstr[bytesize] = 0_u8
          name_array[i] = cstr
          allocated_strings << cstr
          size_array[i] = chrom_sizes[i]
        end

        lib_metadata = LibD4::FileMetadata.new
        lib_metadata.chrom_count = name_count.to_u64
        lib_metadata.chrom_name = name_array
        lib_metadata.chrom_size = size_array
        lib_metadata.dict_type = dict_type.to_lib_dict_type
        lib_metadata.denominator = denominator

        # Set dictionary data based on type
        case dict_type
        in .simple_range?
          # TODO: expose low/high? Using static default matches prior behaviour.
          lib_metadata.dict_data.simple_range.low = 0_i32
          lib_metadata.dict_data.simple_range.high = 128_i32
        in .value_map?
          # Empty value map placeholder for now
          lib_metadata.dict_data.value_map.size = 0_u64
          lib_metadata.dict_data.value_map.values = Pointer(Int32).null
        end

        result = LibD4.d4_file_update_metadata(@handle, pointerof(lib_metadata))
        D4.check_result(result, "Failed to update metadata")

        @metadata = Metadata.new(chromosomes, dict_type, denominator)
      rescue e
        # Re-raise after ensure cleanup
        raise e
      ensure
        # Free all allocated C strings and arrays
        allocated_strings.each do |ptr|
          LibC.free(ptr.as(Void*)) unless ptr.null?
        end
        LibC.free(name_array.as(Void*)) unless name_array.null?
        LibC.free(size_array.as(Void*)) unless size_array.null?
      end
    end

    # Set chromosomes from an array of tuples
    def set_chromosomes(chromosomes : Array(Tuple(String, UInt32)), dict_type : DictType = DictType::SimpleRange, denominator : Float64 = 1.0)
      chrom_hash = Hash(String, UInt32).new
      chromosomes.each do |name, size|
        chrom_hash[name] = size
      end
      set_chromosomes(chrom_hash, dict_type, denominator)
    end

    # Write values to a specific chromosome starting at a position
    def write_values(chromosome : String, position : UInt32, values : Array(Int32))
      check_not_closed

      unless has_chromosome?(chromosome)
        raise D4Error.new("Chromosome '#{chromosome}' not found")
      end

      seek(chromosome, position)
      write_values(values)
    end

    # Write intervals to a specific chromosome
    def write_intervals(chromosome : String, intervals : Array(Interval))
      check_not_closed

      unless has_chromosome?(chromosome)
        raise D4Error.new("Chromosome '#{chromosome}' not found")
      end

      seek(chromosome, 0_u32)
      write_intervals(intervals)
    end

    # Create intervals from position-value pairs
    def self.create_intervals(positions : Array(UInt32), values : Array(Int32)) : Array(Interval)
      if positions.size != values.size
        raise ArgumentError.new("Positions and values arrays must have the same size")
      end

      intervals = Array(Interval).new
      positions.each_with_index do |pos, i|
        next_pos = i + 1 < positions.size ? positions[i + 1] : pos + 1
        intervals << Interval.new(pos, next_pos, values[i])
      end
      intervals
    end

    # Create intervals from dense values (each position gets one value)
    def self.create_dense_intervals(start_position : UInt32, values : Array(Int32)) : Array(Interval)
      intervals = Array(Interval).new
      values.each_with_index do |value, i|
        pos = start_position + i.to_u32
        intervals << Interval.new(pos, pos + 1, value)
      end
      intervals
    end

    # Convenience method to write dense values as intervals
    def write_dense_values(chromosome : String, start_position : UInt32, values : Array(Int32))
      intervals = File.create_dense_intervals(start_position, values)
      write_intervals(chromosome, intervals)
    end
  end

  # Writer class for creating D4 files
  class Writer
    @file : File

    def initialize(path : String)
      @file = File.open(path, "w")
    end

    def initialize(@file : File); end

    def set_chromosomes(chromosomes : Hash(String, UInt32), dict_type : DictType = DictType::SimpleRange, denominator : Float64 = 1.0)
      @file.set_chromosomes(chromosomes, dict_type, denominator)
    end

    def set_chromosomes(chromosomes : Array(Tuple(String, UInt32)), dict_type : DictType = DictType::SimpleRange, denominator : Float64 = 1.0)
      @file.set_chromosomes(chromosomes, dict_type, denominator)
    end

    def write_values(chromosome : String, position : UInt32, values : Array(Int32))
      @file.write_values(chromosome, position, values)
    end

    def write_intervals(chromosome : String, intervals : Array(Interval))
      return if intervals.empty?
      # 先頭 interval の left にシーク (後退はライブラリが拒否するので intervals[0].left 以前へは行わない)
      @file.seek(chromosome, intervals.first.left)
      @file.write_intervals(intervals)
    end

    def write_dense_values(chromosome : String, start_position : UInt32, values : Array(Int32))
      @file.write_dense_values(chromosome, start_position, values)
    end

    def close
      @file.close
    end

    def closed?
      @file.closed?
    end

    def finalize
      close unless closed?
    end
  end
end
