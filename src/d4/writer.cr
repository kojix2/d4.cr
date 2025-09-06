require "./file"

module D4
  class File
    # Set chromosomes for a new D4 file (write mode)
    def set_chromosomes(chromosomes : Hash(String, UInt32), dict_type : DictType = DictType::SimpleRange, denominator : Float64 = 1.0)
      check_not_closed

      # Prepare chromosome data
      chrom_names = chromosomes.keys.to_a
      chrom_sizes = chromosomes.values.to_a

      # Create C string array for chromosome names
      c_names = chrom_names.map(&.to_unsafe.as(LibC::Char*))

      # Create metadata structure
      lib_metadata = LibD4::FileMetadata.new
      lib_metadata.chrom_count = chromosomes.size.to_u64
      lib_metadata.chrom_name = c_names.to_unsafe
      lib_metadata.chrom_size = chrom_sizes.to_unsafe
      lib_metadata.dict_type = dict_type.to_lib_dict_type
      lib_metadata.denominator = denominator

      # Set dictionary data based on type
      case dict_type
      in .simple_range?
        lib_metadata.dict_data.simple_range.low = 0_i32
        lib_metadata.dict_data.simple_range.high = 128_i32
      in .value_map?
        # For now, use empty value map - could be extended later
        lib_metadata.dict_data.value_map.size = 0_u64
        lib_metadata.dict_data.value_map.values = Pointer(Int32).null
      end

      # Update metadata in the file
      result = LibD4.d4_file_update_metadata(@handle, pointerof(lib_metadata))
      D4.check_result(result, "Failed to update metadata")

      # Update cached metadata
      @metadata = Metadata.new(chromosomes, dict_type, denominator)
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

    def initialize(@file : File)
    end

    # Set up chromosomes for the file
    def set_chromosomes(chromosomes : Hash(String, UInt32), dict_type : DictType = DictType::SimpleRange, denominator : Float64 = 1.0)
      @file.set_chromosomes(chromosomes, dict_type, denominator)
    end

    def set_chromosomes(chromosomes : Array(Tuple(String, UInt32)), dict_type : DictType = DictType::SimpleRange, denominator : Float64 = 1.0)
      @file.set_chromosomes(chromosomes, dict_type, denominator)
    end

    # Write values to a chromosome
    def write_values(chromosome : String, position : UInt32, values : Array(Int32))
      @file.write_values(chromosome, position, values)
    end

    # Write intervals to a chromosome
    def write_intervals(chromosome : String, intervals : Array(Interval))
      @file.write_intervals(chromosome, intervals)
    end

    # Write dense values as intervals
    def write_dense_values(chromosome : String, start_position : UInt32, values : Array(Int32))
      @file.write_dense_values(chromosome, start_position, values)
    end

    # Close the writer
    def close
      @file.close
    end

    # Check if closed
    def closed?
      @file.closed?
    end

    def finalize
      close unless closed?
    end
  end
end
