require "./data_sampler"

module D4Plot
  class PlotSettings
    property point_count : Int32
    property? show_axis_ticks : Bool

    def initialize
      @point_count = DataSampler::DEFAULT_POINT_COUNT
      @show_axis_ticks = true
    end
  end
end
