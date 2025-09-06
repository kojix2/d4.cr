require "./lib_d4"
require "./types"

module D4
  # Main class for D4 file operations
  class File
    @handle : LibD4::D4File
    @metadata : Metadata?
    @closed : Bool = false

    def initialize(@handle : LibD4::D4File)
      D4.check_pointer(@handle, "Failed to initialize D4 file")
    end

    # Open a D4 file
    def self.open(path : String, mode : String = "r")
      handle = LibD4.d4_open(path, mode)
      D4.check_pointer(handle, "Failed to open D4 file: #{path}")
      new(handle)
    end

    # Open a D4 file with a block, automatically closes the file
    def self.open(path : String, mode : String = "r", &block : File -> T) forall T
      file = open(path, mode)
      begin
        yield file
      ensure
        file.close unless file.closed?
      end
    end

    # Close the D4 file
    def close
      return if @closed
      result = LibD4.d4_close(@handle)
      D4.check_result(result, "Failed to close D4 file")
      @closed = true
    end

    # Check if the file is closed
    def closed?
      @closed
    end

    # Load metadata from the file
    def metadata : Metadata
      return @metadata.not_nil! if @metadata

      check_not_closed
      lib_metadata = LibD4::FileMetadata.new
      result = LibD4.d4_file_load_metadata(@handle, pointerof(lib_metadata))
      D4.check_result(result, "Failed to load metadata")

      @metadata = Metadata.new(lib_metadata)

      # Clean up the C metadata structure
      cleanup_lib_metadata(pointerof(lib_metadata))

      @metadata.not_nil!
    end

    # Get chromosome information
    def chromosomes
      metadata.chromosomes
    end

    # Check if a chromosome exists
    def has_chromosome?(name : String)
      metadata.has_chromosome?(name)
    end

    # Get chromosome size
    def chromosome_size(name : String)
      metadata.chromosome_size(name)
    end

    # Seek to a specific position in a chromosome
    def seek(chromosome : String, position : UInt32 = 0_u32)
      check_not_closed
      result = LibD4.d4_file_seek(@handle, chromosome, position)
      D4.check_result(result, "Failed to seek to #{chromosome}:#{position}")
      self
    end

    # Get current position
    def tell
      check_not_closed
      name_buffer = Bytes.new(256)
      position = 0_u32
      result = LibD4.d4_file_tell(@handle, name_buffer.to_unsafe.as(LibC::Char*), name_buffer.size, pointerof(position))
      D4.check_result(result, "Failed to get current position")

      # Find the null terminator to get the actual chromosome name
      null_pos = name_buffer.index(0_u8) || name_buffer.size
      chromosome = String.new(name_buffer[0, null_pos])

      {chromosome, position}
    end

    # Read values from the current position
    def read_values(count : Int32) : Array(Int32)
      check_not_closed
      buffer = Array(Int32).new(count, 0)
      result = LibD4.d4_file_read_values(@handle, buffer.to_unsafe, count.to_u64)
      actual_count = D4.check_ssize_result(result, "Failed to read values")
      buffer[0, actual_count.to_i]
    end

    # Read intervals from the current position
    def read_intervals(count : Int32) : Array(Interval)
      check_not_closed
      lib_intervals = Array(LibD4::Interval).new(count) { LibD4::Interval.new }
      result = LibD4.d4_file_read_intervals(@handle, lib_intervals.to_unsafe, count.to_u64)
      actual_count = D4.check_ssize_result(result, "Failed to read intervals")

      intervals = Array(Interval).new(actual_count.to_i)
      actual_count.to_i.times do |i|
        intervals << Interval.new(lib_intervals[i])
      end
      intervals
    end

    # Write values to the current position
    def write_values(values : Array(Int32))
      check_not_closed
      result = LibD4.d4_file_write_values(@handle, values.to_unsafe, values.size.to_u64)
      D4.check_ssize_result(result, "Failed to write values")
      values.size
    end

    # Write intervals to the current position
    def write_intervals(intervals : Array(Interval))
      check_not_closed
      lib_intervals = intervals.map(&.to_lib_interval)
      result = LibD4.d4_file_write_intervals(@handle, lib_intervals.to_unsafe, intervals.size.to_u64)
      D4.check_ssize_result(result, "Failed to write intervals")
      intervals.size
    end

    # Get values for a specific region
    def values(chromosome : String, start : UInt32 = 0_u32, stop : UInt32? = nil) : Array(Int32)
      check_not_closed

      unless has_chromosome?(chromosome)
        raise D4Error.new("Chromosome '#{chromosome}' not found")
      end

      chrom_size = chromosome_size(chromosome)
      raise D4Error.new("Chromosome '#{chromosome}' not found") unless chrom_size

      actual_stop = stop || chrom_size
      actual_stop = Math.min(actual_stop, chrom_size)

      if start >= actual_stop
        return Array(Int32).new
      end

      seek(chromosome, start)
      count = (actual_stop - start).to_i
      read_values(count)
    end

    # Build SFI index for the file
    def self.build_index(path : String)
      result = LibD4.d4_index_build_sfi(path)
      D4.check_result(result, "Failed to build SFI index for #{path}")
    end

    private def check_not_closed
      if @closed
        raise D4Error.new("D4 file is closed")
      end
    end

    private def cleanup_lib_metadata(lib_metadata : LibD4::FileMetadata*)
      return if lib_metadata.null?

      metadata = lib_metadata.value
      return if metadata.chrom_count == 0

      # Free chromosome names
      metadata.chrom_count.times do |i|
        LibC.free(metadata.chrom_name[i].as(Void*))
      end

      # Free arrays
      LibC.free(metadata.chrom_name.as(Void*))
      LibC.free(metadata.chrom_size.as(Void*))

      # Clean up value map if needed
      if metadata.dict_type == LibD4::DictType::ValueMap
        LibC.free(metadata.dict_data.value_map.values.as(Void*))
      end
    end

    def finalize
      close unless @closed
    end
  end
end
