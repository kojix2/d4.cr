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
      return [] of PlotPoint if npoints <= 0

      begin
        region = D4::Region.new(chromosome, start0.to_i64, end0_excl.to_i64)
        count = Math.min(npoints.to_i64, region.length).to_i
        # The plot needs means, not min/max. For wide bins the embedded sum
        # index avoids streaming the entire region; small bins use one scan.
        if d4.default_track.has_index?(D4::IndexKind::Sum) && region.length // count >= 4 * 65_536
          cursor = region.start
          return Array(PlotPoint).new(count) do |index|
            size = region.length // count + (index < region.length % count ? 1 : 0)
            mean = d4.sum(chromosome, cursor, cursor + size).to_f64 / size
            center = cursor + (size - 1) // 2 + 1
            cursor += size
            {center.to_u32, mean}
          end
        end
        d4.sample(region, bins: npoints).map do |bin|
          center0 = bin.start + (bin.length - 1) // 2
          {(center0 + 1).to_u32, bin.mean.not_nil!}
        end
      rescue ex
        Log.error "Error getting data: #{ex.message}"
        [] of PlotPoint
      end
    end
  end
end
