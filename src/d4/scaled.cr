module D4
  alias ScaledInterval = Interval(Float64)

  class ScaledTrack
    def initialize(@raw : Track)
    end

    def metadata : Metadata
      @raw.metadata
    end

    def value(chromosome : String, position : Int) : Float64
      @raw.value(chromosome, position).to_f64 / denominator
    end

    def values(chromosome : String, start : Int = 0, stop : Int? = nil) : Array(Float64)
      @raw.check_open
      region = Region.new(chromosome, start.to_i64, (stop || @raw.chromosome_size(chromosome)).to_i64)
      raise ArgumentError.new("invalid region") if region.stop > @raw.chromosome_size(chromosome)
      # The raw materialization limit applies equally to the larger float result.
      raise AllocationLimitError.new("scaled values exceed the configured materialization limit") if region.length > Int32::MAX || region.length * sizeof(Float64) > @raw.materialization_limit
      output = Array(Float64).new(region.length.to_i, 0.0)
      return output if region.length == 0
      offset = 0
      scan_values(region, Slice(Float64).new(Math.min(region.length, 65_536_i64).to_i)) do |_start, values, count|
        count.times { |index| output[offset + index] = values[index] }
        offset += count
      end
      output
    end

    def read_values_into(chromosome : String, start : Int, buffer : Slice(Float64)) : Int32
      @raw.read_values_into(chromosome, start, Slice(Int32).new(0))
      return 0 if buffer.empty? || start.to_i64 == @raw.chromosome_size(chromosome)
      count = 0
      length = Math.min(buffer.size.to_i64, @raw.chromosome_size(chromosome) - start.to_i64)
      scan_values(Region.new(chromosome, start.to_i64, start.to_i64 + length), buffer) do |_offset, _values, value_count|
        count += value_count
      end
      count
    end

    def scan_values(region : Region, buffer : Slice(Float64), & : Int64, Slice(Float64), Int32 -> Nil) : Nil
      raise ArgumentError.new("scan buffer must not be empty") if buffer.empty?
      raw = Slice(Int32).new(Math.min(buffer.size, 65_536))
      @raw.scan_values(region, raw) do |position, values, count|
        count.times { |index| buffer[index] = values[index].to_f64 / denominator }
        yield position, buffer[0, count], count
      end
    end

    def each_value(chromosome : String, start : Int = 0, stop : Int? = nil, & : Float64 -> Nil) : Nil
      @raw.each_value(chromosome, start, stop) { |value| yield value.to_f64 / denominator }
    end

    def each_value(chromosome : String, start : Int = 0, stop : Int? = nil)
      ScaledValueIterator.new(@raw.each_value(chromosome, start, stop), denominator)
    end

    def each_interval(chromosome : String, start : Int = 0, stop : Int? = nil, & : ScaledInterval -> Nil) : Nil
      @raw.each_interval(chromosome, start, stop) do |interval|
        yield ScaledInterval.new(interval.left, interval.right, interval.value.to_f64 / denominator)
      end
    end

    def each_interval(chromosome : String, start : Int = 0, stop : Int? = nil)
      ScaledIntervalIterator.new(@raw.each_interval(chromosome, start, stop), denominator)
    end

    def sum(chromosome : String, start : Int = 0, stop : Int? = nil) : Float64
      @raw.sum(chromosome, start, stop).to_f64 / denominator
    end

    def mean(chromosome : String, start : Int = 0, stop : Int? = nil) : Float64?
      @raw.mean(chromosome, start, stop).try { |value| value / denominator }
    end

    def minmax(chromosome : String, start : Int = 0, stop : Int? = nil) : Tuple(Float64, Float64)?
      @raw.minmax(chromosome, start, stop).try { |min, max| {min.to_f64 / denominator, max.to_f64 / denominator} }
    end

    private def denominator : Float64
      metadata.denominator
    end
  end

  class ScaledValueIterator
    include Iterator(Float64)

    def initialize(@raw : ValueIterator, @denominator : Float64); end

    def next
      value = @raw.next
      value.is_a?(Iterator::Stop) ? stop : value.to_f64 / @denominator
    end
  end

  class ScaledIntervalIterator
    include Iterator(ScaledInterval)

    def initialize(@raw : IntervalIterator, @denominator : Float64); end

    def next
      interval = @raw.next
      return stop if interval.is_a?(Iterator::Stop)
      ScaledInterval.new(interval.left, interval.right, interval.value.to_f64 / @denominator)
    end
  end

  class Track
    @scaled : ScaledTrack?

    def scaled : ScaledTrack
      @scaled ||= ScaledTrack.new(self)
    end

    def materialization_limit : Int64
      @options.max_materialized_bytes
    end
  end

  class File
    def scaled : ScaledTrack
      default_track.scaled
    end
  end
end
