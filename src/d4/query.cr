require "./file"

module D4
  class File
    # Query intervals in a specific region with an iterator
    def query(chromosome : String, start : UInt32 = 0_u32, stop : UInt32? = nil, &block : Interval -> Nil)
      check_not_closed

      unless has_chromosome?(chromosome)
        raise D4Error.new("Chromosome '#{chromosome}' not found")
      end

      chrom_size = chromosome_size(chromosome)
      raise D4Error.new("Chromosome '#{chromosome}' not found") unless chrom_size

      actual_stop = stop || chrom_size
      actual_stop = Math.min(actual_stop, chrom_size)

      if start >= actual_stop
        return
      end

      seek(chromosome, start)
      buffer = Array(LibD4::Interval).new(1000) { LibD4::Interval.new }
      done = false
      name_buffer = Bytes.new(256)
      position = 0_u32

      while !done
        # Check current position
        result = LibD4.d4_file_tell(@handle, name_buffer.to_unsafe.as(LibC::Char*), name_buffer.size, pointerof(position))
        D4.check_result(result, "Failed to get current position during query")

        # Find null terminator and check chromosome name
        null_pos = name_buffer.index(0_u8) || name_buffer.size
        current_chrom = String.new(name_buffer[0, null_pos])

        # Stop if we've moved to a different chromosome
        break if current_chrom != chromosome

        # Read intervals
        count = LibD4.d4_file_read_intervals(@handle, buffer.to_unsafe, buffer.size.to_u64)
        actual_count = D4.check_ssize_result(count, "Failed to read intervals during query")

        actual_count.to_i.times do |i|
          lib_interval = buffer[i]
          interval = Interval.new(lib_interval)

          # Apply region filtering
          filtered_left = Math.max(start, interval.left)
          filtered_right = Math.min(actual_stop, interval.right)

          if filtered_left < filtered_right
            filtered_interval = Interval.new(filtered_left, filtered_right, interval.value)
            yield filtered_interval
          end

          # Stop if we've reached the end of the requested region
          if interval.right >= actual_stop
            done = true
            break
          end
        end

        # If we read fewer intervals than requested, we've reached the end
        if actual_count.to_i < buffer.size
          break
        end
      end
    end

    # Query intervals and return as an array
    def query(chromosome : String, start : UInt32 = 0_u32, stop : UInt32? = nil) : Array(Interval)
      intervals = Array(Interval).new
      query(chromosome, start, stop) do |interval|
        intervals << interval
      end
      intervals
    end

    # Query intervals and return an iterator
    def query_iter(chromosome : String, start : UInt32 = 0_u32, stop : UInt32? = nil)
      QueryIterator.new(self, chromosome, start, stop)
    end
  end

  # Iterator for querying D4 intervals
  class QueryIterator
    include Iterator(Interval)

    @file : File
    @chromosome : String
    @start : UInt32
    @stop : UInt32
    @buffer : Array(LibD4::Interval)
    @buffer_index : Int32
    @buffer_count : Int32
    @done : Bool
    @name_buffer : Bytes

    def initialize(@file : File, @chromosome : String, @start : UInt32, stop : UInt32?)
      @file.check_not_closed

      unless @file.has_chromosome?(@chromosome)
        raise D4Error.new("Chromosome '#{@chromosome}' not found")
      end

      chrom_size = @file.chromosome_size(@chromosome)
      raise D4Error.new("Chromosome '#{@chromosome}' not found") unless chrom_size

      @stop = stop || chrom_size
      @stop = Math.min(@stop, chrom_size)

      @buffer = Array(LibD4::Interval).new(1000) { LibD4::Interval.new }
      @buffer_index = 0
      @buffer_count = 0
      @done = @start >= @stop
      @name_buffer = Bytes.new(256)

      unless @done
        @file.seek(@chromosome, @start)
        fill_buffer
      end
    end

    def next
      return stop if @done

      while @buffer_index >= @buffer_count
        fill_buffer
        return stop if @done
      end

      lib_interval = @buffer[@buffer_index]
      @buffer_index += 1

      interval = Interval.new(lib_interval)

      # Apply region filtering
      filtered_left = Math.max(@start, interval.left)
      filtered_right = Math.min(@stop, interval.right)

      if filtered_left < filtered_right
        filtered_interval = Interval.new(filtered_left, filtered_right, interval.value)

        # Check if we've reached the end of the requested region
        if interval.right >= @stop
          @done = true
        end

        filtered_interval
      else
        # Skip this interval and try the next one
        self.next
      end
    end

    private def fill_buffer
      return if @done

      # Check current position
      position = 0_u32
      result = LibD4.d4_file_tell(@file.@handle, @name_buffer.to_unsafe.as(LibC::Char*), @name_buffer.size, pointerof(position))
      D4.check_result(result, "Failed to get current position during iteration")

      # Find null terminator and check chromosome name
      null_pos = @name_buffer.index(0_u8) || @name_buffer.size
      current_chrom = String.new(@name_buffer[0, null_pos])

      # Stop if we've moved to a different chromosome
      if current_chrom != @chromosome
        @done = true
        return
      end

      # Read intervals
      count = LibD4.d4_file_read_intervals(@file.@handle, @buffer.to_unsafe, @buffer.size.to_u64)
      @buffer_count = D4.check_ssize_result(count, "Failed to read intervals during iteration").to_i
      @buffer_index = 0

      # If we read fewer intervals than requested, we've reached the end
      if @buffer_count < @buffer.size
        @done = true
      end

      # Check if any interval in the buffer extends beyond our stop position
      @buffer_count.times do |i|
        if @buffer[i].right >= @stop
          @done = true
          break
        end
      end
    end
  end
end
