module D4Plot
  struct PlotGeometry
    getter left : Float64, top : Float64, width : Float64, height : Float64, annotation_top : Float64

    def initialize(area_width : Float64, area_height : Float64, annotation_height : Float64)
      @left = 82.0
      @top = 92.0
      @width = Math.max(area_width - @left - 38.0, 1.0)
      @height = Math.max(area_height - @top - 58.0 - annotation_height - (annotation_height > 0 ? 28.0 : 0.0), 1.0)
      @annotation_top = @top + @height + 58.0
    end

    def fraction(x : Float64) : Float64
      ((x - @left) / @width).clamp(0.0, 1.0)
    end

    def contains?(x : Float64, y : Float64) : Bool
      x >= @left && x <= @left + @width && y >= @top && y <= @top + @height
    end

    # Position is a 0-based boundary, shared by bins and annotation intervals.
    def x_for(position : Int64, region : Region) : Float64
      @left + (position - region.start0).to_f64 / region.length * @width
    end
  end
end
