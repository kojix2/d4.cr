require "./data_sampler"

module D4Plot
  module DisplayFormat
    def self.position(value : Int) : String
      value.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
    end

    def self.value(value : Float64) : String
      "%.5g" % value
    end
  end

  # Bin edges are retained through the region and count, without materializing
  # per-base data. All rendering, inspection and export use these same edges.
  class SampledView
    getter region : Region
    getter points : Array(PlotPoint)

    def initialize(@region : Region, @points : Array(PlotPoint))
      raise ArgumentError.new("No samples returned") if points.empty?
    end

    def bin_edges(index : Int32) : Tuple(Int64, Int64)
      base = @region.length.to_i64 // @points.size
      extra = @region.length.to_i64 % @points.size
      left = @region.start0.to_i64 + index * base + Math.min(index, extra)
      {left, left + base + (index < extra ? 1 : 0)}
    end

    def bin_at(fraction : Float64) : Int32
      offset = (fraction.clamp(0.0, 1.0) * @region.length).floor.to_i64.clamp(0_i64, @region.length.to_i64 - 1)
      base = @region.length.to_i64 // @points.size
      extra = @region.length.to_i64 % @points.size
      boundary = (base + 1) * extra
      (offset < boundary ? offset // (base + 1) : extra + (offset - boundary) // base).to_i
    end

    def mean : Float64
      total = 0.0
      @points.each_with_index do |point, index|
        left, right = bin_edges(index)
        total += point[1] * (right - left)
      end
      total / @region.length
    end

    def resolution : String
      return "1 bp / bin" if @points.size == @region.length
      base = @region.length // @points.size
      width = DisplayFormat.position(base)
      width += "–#{DisplayFormat.position(base + 1)}" if @region.length % @points.size != 0
      "#{width} bp / bin (mean)"
    end

    def inspect_bin(index : Int32) : String
      left, right = bin_edges(index)
      "#{@region.chromosome}:#{DisplayFormat.position(left + 1)}-#{DisplayFormat.position(right)} | Mean: #{DisplayFormat.value(@points[index][1])} | #{DisplayFormat.position(right - left)} bp"
    end

    def write_bedgraph(io : IO) : Nil
      io << "# Binned means; coordinates: 0-based, half-open; D4 denominator applied\n"
      @points.each_with_index do |point, index|
        left, right = bin_edges(index)
        io << @region.chromosome << '\t' << left << '\t' << right << '\t' << point[1] << '\n'
      end
    end
  end

  class ViewHistory
    @regions = [] of Region
    @cursor = -1

    def clear : Nil
      @regions.clear
      @cursor = -1
    end

    def record(region : Region) : Nil
      return if @regions[@cursor]? == region
      @regions = @regions[0, @cursor + 1]
      @regions << region
      @regions.shift if @regions.size > 100
      @cursor = @regions.size - 1
    end

    def back? : Bool
      @cursor > 0
    end

    def forward? : Bool
      @cursor + 1 < @regions.size
    end

    def back : Region?
      return unless back?
      @cursor -= 1
      @regions[@cursor]
    end

    def forward : Region?
      return unless forward?
      @cursor += 1
      @regions[@cursor]
    end
  end
end
