module D4
  class BinSummary
    getter start : Int64
    getter stop : Int64
    getter summary : Summary

    def initialize(@start : Int64, @stop : Int64, @summary : Summary); end

    def length : Int64
      @stop - @start
    end

    def mean : Float64?
      @summary.mean
    end

    def min : Int32?
      @summary.min
    end

    def max : Int32?
      @summary.max
    end

    def sum : Int64
      @summary.sum
    end
  end

  class BinIterator
    include Iterator(BinSummary)
    @values : ValueIterator

    def initialize(@track : Track, @region : Region, @bin_size : Int64)
      raise ArgumentError.new("bin_size must be positive") if @bin_size <= 0
      @values = @track.each_value(region.chromosome, region.start, region.stop)
      @position = region.start
    end

    def next
      @track.check_open
      return stop if @position >= @region.stop
      left = @position
      right = left + Math.min(@bin_size, @region.stop - left)
      sum = 0_i64
      min = Int32::MAX
      max = Int32::MIN
      (right - left).times do
        value = @values.next
        return stop if value.is_a?(Iterator::Stop)
        sum += value
        min = value if value < min
        max = value if value > max
      end
      @position = right
      BinSummary.new(left, right, Summary.new(right - left, sum, min, max))
    end
  end

  class Track
    def each_bin(region : Region, *, bin_size : Int, & : BinSummary -> Nil) : Nil
      iterator = each_bin(region, bin_size: bin_size)
      while item = iterator.next
        break if item.is_a?(Iterator::Stop)
        yield item
      end
    end

    def each_bin(region : Region, *, bin_size : Int) : BinIterator
      check_open
      raise ArgumentError.new("invalid region") if region.stop > chromosome_size(region.chromosome)
      BinIterator.new(self, region, bin_size.to_i64)
    end

    def sample(region : Region, *, bins : Int32 = 256) : Array(BinSummary)
      raise ArgumentError.new("bins must be positive") if bins <= 0
      check_open
      raise ArgumentError.new("invalid region") if region.stop > chromosome_size(region.chromosome)
      count = Math.min(bins.to_i64, region.length).to_i
      raise AllocationLimitError.new("sample exceeds configured limit") if count.to_i64 * 64 > @options.max_materialized_bytes
      result = Array(BinSummary).new(count)
      return result if count == 0
      values = each_value(region.chromosome, region.start, region.stop)
      cursor = region.start
      count.times do |index|
        size = region.length // count + (index < region.length % count ? 1 : 0)
        left = cursor
        sum = 0_i64
        min = Int32::MAX
        max = Int32::MIN
        size.times do
          value = values.next.as(Int32)
          sum += value
          min = value if value < min
          max = value if value > max
        end
        cursor += size
        result << BinSummary.new(left, cursor, Summary.new(size, sum, min, max))
      end
      result
    end
  end

  class File
    def each_bin(region : Region, *, bin_size : Int, & : BinSummary -> Nil) : Nil
      default_track.each_bin(region, bin_size: bin_size) { |bin| yield bin }
    end

    def each_bin(region : Region, *, bin_size : Int) : BinIterator
      default_track.each_bin(region, bin_size: bin_size)
    end

    def sample(region : Region, *, bins : Int32 = 256) : Array(BinSummary)
      default_track.sample(region, bins: bins)
    end
  end
end
