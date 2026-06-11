require "./data_sampler"

module D4Plot
  class PlotSettings
    alias PlotColor = Tuple(Float64, Float64, Float64, Float64)

    property point_count : Int32
    property plot_color : PlotColor
    property? use_sum_index : Bool
    property? show_axis_ticks : Bool
    property? y_axis_from_zero : Bool

    def initialize
      @point_count = DataSampler::DEFAULT_POINT_COUNT
      @plot_color = {0.0, 0.4, 0.8, 1.0}
      @use_sum_index = true
      @show_axis_ticks = true
      @y_axis_from_zero = true
    end
  end
end
