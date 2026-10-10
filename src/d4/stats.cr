module D4
  class HistogramTails
    getter below : Int64
    getter above : Int64

    def initialize(@below : Int64, @above : Int64); end
  end

  class Histogram
    getter start : Int32
    getter stop : Int64
    getter counts : Array(Int64)
    getter below : Int64
    getter above : Int64

    def initialize(@start : Int32, @stop : Int64, @counts : Array(Int64), @below : Int64, @above : Int64); end

    def quantile(q : Float64) : Int32?
      raise ArgumentError.new("quantile must be between 0 and 1") unless q.finite? && 0.0 <= q <= 1.0
      raise IncompleteHistogramError.new("histogram excludes observed values") if @below > 0 || @above > 0
      total = @counts.sum(0_i64)
      return nil if total == 0
      rank = Math.max(1_i64, (q * total).ceil.to_i64)
      seen = 0_i64
      @counts.each_with_index do |count, index|
        seen += count
        return (@start.to_i64 + index).to_i32 if seen >= rank
      end
      nil
    end
  end

  class ExactHistogram
    getter counts : Hash(Int32, Int64)

    def initialize(@counts : Hash(Int32, Int64)); end

    def quantile(q : Float64) : Int32?
      raise ArgumentError.new("quantile must be between 0 and 1") unless q.finite? && 0.0 <= q <= 1.0
      total = @counts.values.sum(0_i64)
      return nil if total == 0
      rank = Math.max(1_i64, (q * total).ceil.to_i64)
      seen = 0_i64
      @counts.keys.sort.each do |value|
        seen += @counts[value]
        return value if seen >= rank
      end
      nil
    end
  end

  class Coverage
    getter thresholds : Array(Int32)
    getter counts : Array(Int64)
    getter length : Int64

    def initialize(@thresholds : Array(Int32), @counts : Array(Int64), @length : Int64); end

    def fraction(index : Int) : Float64?
      return nil if @length == 0
      @counts[index].to_f64 / @length
    end
  end

  class Track
    def minmax(chromosome : String, start : Int = 0, stop : Int? = nil) : Tuple(Int32, Int32)?
      result = summary(chromosome, start, stop)
      min = result.min
      max = result.max
      min && max ? {min, max} : nil
    end

    def minmax(region : Region) : Tuple(Int32, Int32)?
      minmax(region.chromosome, region.start, region.stop)
    end

    def histogram_into(region : Region, counts : Slice(Int64), *, value_range : Range(Int32, Int32)) : HistogramTails
      first = value_range.begin.to_i64
      last = value_range.end.to_i64 + (value_range.excludes_end? ? 0_i64 : 1_i64)
      raise ArgumentError.new("invalid histogram value range") if last < first || last - first != counts.size
      # Check the requested region before changing the caller's buffer.
      chromosome(region.chromosome)
      raise ArgumentError.new("invalid region") if region.stop > chromosome_size(region.chromosome)
      counts.fill(0_i64)
      below = 0_i64
      above = 0_i64
      scan_values(region, Slice(Int32).new(65_536)) do |_position, values, count|
        count.times do |index|
          value = values[index].to_i64
          if value < first
            below += 1
          elsif value >= last
            above += 1
          else
            counts[(value - first).to_i] += 1
          end
        end
      end
      HistogramTails.new(below, above)
    end

    def histogram(region : Region, *, value_range : Range(Int32, Int32)) : Histogram
      first = value_range.begin.to_i64
      last = value_range.end.to_i64 + (value_range.excludes_end? ? 0_i64 : 1_i64)
      size = last - first
      raise ArgumentError.new("invalid histogram value range") if size < 0
      raise AllocationLimitError.new("histogram exceeds configured limit") if size > Int32::MAX || size * sizeof(Int64) > @options.max_materialized_bytes
      counts = Array(Int64).new(size.to_i, 0_i64)
      tails = histogram_into(region, counts.to_unsafe.to_slice(counts.size), value_range: value_range)
      Histogram.new(value_range.begin, last, counts, tails.below, tails.above)
    end

    def exact_histogram(region : Region, *, max_values : Int32 = 4096) : ExactHistogram
      raise ArgumentError.new("max_values must be positive") if max_values <= 0
      counts = Hash(Int32, Int64).new(0_i64)
      scan_values(region, Slice(Int32).new(65_536)) do |_position, values, count|
        count.times do |index|
          value = values[index]
          raise AllocationLimitError.new("too many distinct histogram values") if !counts.has_key?(value) && counts.size >= max_values
          counts[value] += 1
        end
      end
      ExactHistogram.new(counts)
    end

    def coverage_into(region : Region, thresholds : Slice(Int32), counts : Slice(Int64)) : Int64
      raise ArgumentError.new("threshold and count buffers must have the same size") unless thresholds.size == counts.size
      chromosome(region.chromosome)
      raise ArgumentError.new("invalid region") if region.stop > chromosome_size(region.chromosome)
      counts.fill(0_i64)
      scan_values(region, Slice(Int32).new(65_536)) do |_position, values, count|
        count.times do |index|
          value = values[index]
          thresholds.size.times { |threshold| counts[threshold] += 1 if value >= thresholds[threshold] }
        end
      end
      region.length
    end

    def coverage(region : Region, *, thresholds : Array(Int32)) : Coverage
      raise AllocationLimitError.new("coverage exceeds configured limit") if thresholds.size.to_i64 * sizeof(Int64) > @options.max_materialized_bytes
      counts = Array(Int64).new(thresholds.size, 0_i64)
      length = coverage_into(region, thresholds.to_unsafe.to_slice(thresholds.size), counts.to_unsafe.to_slice(counts.size))
      Coverage.new(thresholds.dup, counts, length)
    end
  end

  class File
    def minmax(chromosome : String, start : Int = 0, stop : Int? = nil) : Tuple(Int32, Int32)?
      default_track.minmax(chromosome, start, stop)
    end

    def minmax(region : Region) : Tuple(Int32, Int32)?
      default_track.minmax(region)
    end

    def histogram(region : Region, *, value_range : Range(Int32, Int32)) : Histogram
      default_track.histogram(region, value_range: value_range)
    end

    def histogram_into(region : Region, counts : Slice(Int64), *, value_range : Range(Int32, Int32)) : HistogramTails
      default_track.histogram_into(region, counts, value_range: value_range)
    end

    def exact_histogram(region : Region, *, max_values : Int32 = 4096) : ExactHistogram
      default_track.exact_histogram(region, max_values: max_values)
    end

    def coverage(region : Region, *, thresholds : Array(Int32)) : Coverage
      default_track.coverage(region, thresholds: thresholds)
    end

    def coverage_into(region : Region, thresholds : Slice(Int32), counts : Slice(Int64)) : Int64
      default_track.coverage_into(region, thresholds, counts)
    end
  end
end
