require "./data_sampler"

module D4Plot
  class PlotSettings
    alias PlotColor = Tuple(Float64, Float64, Float64, Float64)

    property point_count : Int32
    property annotation_feature_limit : Int32
    property plot_color : PlotColor
    property? use_sum_index : Bool
    property? show_axis_ticks : Bool
    property? y_axis_from_zero : Bool
    property y_min : Float64?
    property y_max : Float64?
    property h_lines : Array(Float64)

    def initialize
      @point_count = DataSampler::DEFAULT_POINT_COUNT
      @annotation_feature_limit = 500
      @plot_color = {0.0, 0.4, 0.8, 1.0}
      @use_sum_index = true
      @show_axis_ticks = true
      @y_axis_from_zero = true
      @y_min = nil
      @y_max = nil
      @h_lines = [] of Float64
    end

    def y_range(min_value : Float64, max_value : Float64) : Tuple(Float64, Float64)
      low = @y_axis_from_zero ? Math.min(0.0, min_value) : min_value
      high = @y_axis_from_zero ? Math.max(0.0, max_value) : max_value
      padding = high == low ? Math.max(high.abs * 0.1, 1.0) : (high - low) * 0.08
      low -= padding unless @y_axis_from_zero && low == 0
      high += padding
      low = @y_min || low
      high = @y_max || high
      high = low + 1.0 if high <= low
      {low, high}
    end
  end
end
