require "./file"

module D4
  class File
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
      return if intervals.empty?

      unless has_chromosome?(chromosome)
        raise D4Error.new("Chromosome '#{chromosome}' not found")
      end

      seek(chromosome, intervals.first.left)
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
