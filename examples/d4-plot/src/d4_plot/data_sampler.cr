require "../../../../src/d4"
require "./log"
require "./region"

module D4Plot
  alias PlotPoint = Tuple(UInt32, Float64)

  class DataSampler
    DEFAULT_POINT_COUNT = 256

    def self.downsample(d4 : D4::File, region : Region, npoints : Int32 = DEFAULT_POINT_COUNT) : Array(PlotPoint)
      downsample(d4, region.chromosome, region.start0, region.end0_exclusive, npoints)
    end

    # Parameters are internal 0-based half-open [start0, end0_excl).
    # Returned coordinates are 1-based for user-facing axis display.
    def self.downsample(d4 : D4::File, chromosome : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32 = DEFAULT_POINT_COUNT) : Array(PlotPoint)
      return [] of PlotPoint if end0_excl <= start0

      begin
        total_len = end0_excl - start0
        data = [] of PlotPoint

        if total_len <= npoints.to_u32
          (start0...end0_excl).each do |pos0|
            value = d4.mean(chromosome, pos0, pos0 + 1_u32)
            data << {pos0 + 1_u32, value}
          end
          return data
        end

        bin_size = (total_len // npoints.to_u32).to_u32
        bin_size = 1_u32 if bin_size == 0

        current = start0
        npoints.times do
          break if current >= end0_excl

          bin_start = current
          bin_end_excl = bin_start + bin_size
          bin_end_excl = end0_excl if bin_end_excl > end0_excl
          center0 = (bin_start + (bin_end_excl - 1_u32)) // 2
          mean_value = d4.mean(chromosome, bin_start, bin_end_excl)
          data << {center0 + 1_u32, mean_value}
          current = bin_end_excl
        end

        data
      rescue ex
        Log.error "Error getting data: #{ex.message}"
        [] of PlotPoint
      end
    end
  end
end
