require "d4"
require "./log"
require "./region"

module D4Plot
  alias PlotPoint = Tuple(UInt32, Float64)

  class DataSampler
    DEFAULT_POINT_COUNT =        256
    MIN_INDEX_BIN_SIZE  = 65_536_i64

    def self.downsample(d4 : D4::File | D4::Track, region : Region, npoints : Int32 = DEFAULT_POINT_COUNT, use_sum_index : Bool = true, cancelled : Proc(Bool)? = nil) : Array(PlotPoint)
      raise ArgumentError.new("Invalid region") unless region.valid?
      downsample(d4, region.chromosome, region.start0, region.end0_exclusive, npoints, use_sum_index, cancelled)
    end

    # Parameters are internal 0-based half-open [start0, end0_excl).
    # Returned coordinates are 1-based for user-facing axis display.
    def self.downsample(d4 : D4::File | D4::Track, chromosome : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32 = DEFAULT_POINT_COUNT, use_sum_index : Bool = true, cancelled : Proc(Bool)? = nil) : Array(PlotPoint)
      return [] of PlotPoint if end0_excl <= start0
      return [] of PlotPoint if npoints <= 0

      track = d4.is_a?(D4::File) ? d4.default_track : d4
      raise ArgumentError.new("Region exceeds chromosome length") if end0_excl > track.chromosome_size(chromosome)
      total_len = end0_excl.to_i64 - start0
      count = Math.min(npoints.to_i64, total_len).to_i
      points = if use_sum_index && total_len // count >= MIN_INDEX_BIN_SIZE && track.has_index?(D4::IndexKind::Sum)
                 indexed_sample(track, chromosome, start0, end0_excl, count, cancelled)
               else
                 stream_sample(track, chromosome, start0, end0_excl, count, cancelled)
               end
      denominator = track.metadata.denominator
      if denominator != 1.0
        points.map! { |pos, value| {pos, value / denominator} }
      end
      points
    end

    private def self.indexed_sample(d4 : D4::Track, chromosome : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32, cancelled) : Array(PlotPoint)
      data = Array(PlotPoint).new(npoints)
      each_bin(start0, end0_excl, npoints) do |bin_start, bin_end_excl|
        raise SamplingCancelled.new if cancelled.try(&.call)
        center0 = (bin_start.to_u64 + bin_end_excl - 1) // 2
        sum = d4.sum(chromosome, bin_start, bin_end_excl, index: D4::IndexPolicy::Auto)
        data << {(center0 + 1).to_u32, sum.to_f64 / (bin_end_excl - bin_start)}
      end
      data
    end

    private def self.stream_sample(d4 : D4::Track, chromosome : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32, cancelled) : Array(PlotPoint)
      length = end0_excl.to_i64 - start0
      base = length // npoints
      extra = length % npoints
      points = Array(PlotPoint).new(npoints)
      bin_index = 0
      bin_start = start0.to_i64
      bin_stop = bin_start + base + (bin_index < extra ? 1 : 0)
      sum = 0_i64
      scratch = Slice(Int32).new(65_536)
      d4.scan_values(D4::Region.new(chromosome, bin_start, end0_excl.to_i64), scratch) do |block_start, values, size|
        raise SamplingCancelled.new if cancelled.try(&.call)
        offset = 0
        while offset < size
          take = Math.min(size - offset, (bin_stop - block_start - offset).to_i)
          limit = offset + take
          while offset < limit
            sum += values.unsafe_fetch(offset)
            offset += 1
          end
          if block_start + offset == bin_stop
            center = (bin_start + bin_stop - 1) // 2 + 1
            points << {center.to_u32, sum.to_f64 / (bin_stop - bin_start)}
            bin_index += 1
            if bin_index < npoints
              bin_start = bin_stop
              bin_stop += base + (bin_index < extra ? 1 : 0)
              sum = 0_i64
            end
          end
        end
      end
      points
    end

    private def self.each_bin(start0 : UInt32, end0_excl : UInt32, npoints : Int32, & : UInt32, UInt32 ->)
      total_len = end0_excl - start0
      bins = Math.min(npoints.to_u32, total_len)
      base_size = total_len // bins
      extra_bases = total_len % bins

      current = start0
      bins.times do |index|
        width = base_size
        width += 1_u32 if index < extra_bases

        bin_start = current
        bin_end_excl = bin_start + width
        yield bin_start, bin_end_excl
        current = bin_end_excl
      end
    end
  end

  class SamplingCancelled < Exception
  end
end
