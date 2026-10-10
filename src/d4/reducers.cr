require "wait_group"

module D4
  # Runs a bounded number of fibers on one process-wide parallel scheduler.
  # The scheduler grows threads on demand; it is never created per query.
  class ParallelWork
    @@mutex = Mutex.new
    @@context : Fiber::ExecutionContext::Parallel? = nil

    def self.run(count : Int32, workers : Int32, &block : Int32, Slice(Int32) -> Nil) : Nil
      return if count == 0
      active = Math.min(Math.min(count, workers), System.cpu_count)
      jobs = Channel(Int32).new(Math.min(count, active * 2))
      group = WaitGroup.new(active)
      error_mutex = Mutex.new
      error = nil.as(Exception?)
      active.times do
        context.spawn do
          begin
            scratch = Slice(Int32).new(65_536)
            while index = jobs.receive?
              next if error_mutex.synchronize { !error.nil? }
              begin
                block.call(index, scratch)
              rescue ex
                error_mutex.synchronize { error ||= ex }
              end
            end
          ensure
            group.done
          end
        end
      end
      count.times { |index| jobs.send(index) }
      jobs.close
      group.wait
      raise error.not_nil! if error
    end

    private def self.context : Fiber::ExecutionContext::Parallel
      @@mutex.synchronize do
        @@context ||= Fiber::ExecutionContext::Parallel.new("d4-aggregation", System.cpu_count)
      end
    end
  end

  class RegionResult(T)
    getter index : Int32
    getter region : Region
    getter value : T

    def initialize(@index : Int32, @region : Region, @value : T); end
  end

  class AggregateIterator(D, R)
    include Iterator(RegionResult(R))

    def initialize(@track : Track, @regions : Indexable(Region), @reducer : D,
                   @workers : Int32 = 1, @batch_size : Int32 = 256)
      @index = 0
      @scratch = Slice(Int32).new(65_536)
      @batch = [] of RegionResult(R)
      @batch_index = 0
    end

    def next
      @track.check_open
      return stop if @index >= @regions.size
      if @workers > 1
        if @batch_index >= @batch.size
          start = @index
          finish = Math.min(start + @batch_size, @regions.size)
          @batch = @track.aggregate(@regions[start...finish], @reducer, workers: @workers).map do |result|
            RegionResult.new(start + result.index, result.region, result.value)
          end
          @batch_index = 0
        end
        result = @batch[@batch_index]
        @batch_index += 1
        @index += 1
        return result
      end
      index = @index
      region = @regions[index]
      @index += 1
      RegionResult.new(index, region, @track.aggregate_region(region, @reducer, @scratch))
    end
  end

  module Reducers
    class State
      property length : Int64
      property sum : Int64
      property min : Int32?
      property max : Int32?

      def initialize
        @length = 0_i64
        @sum = 0_i64
        @min = nil.as(Int32?)
        @max = nil.as(Int32?)
      end
    end

    abstract class Basic
      def seed : State
        State.new
      end

      def consume(state : State, start : Int64, stop : Int64, value : Int32) : State
        length = stop - start
        state.length += length
        state.sum += length * value
        state.min = value if state.min.nil? || value < state.min.not_nil!
        state.max = value if state.max.nil? || value > state.max.not_nil!
        state
      end

      # Built-in reducers only depend on the values, not interval boundaries.
      # Consume a decoded block directly, avoiding one virtual call per run.
      def consume_values(state : State, values : Slice(Int32), count : Int32) : State
        sum = state.sum
        min = state.min
        max = state.max
        count.times do |index|
          value = values[index]
          sum += value
          min = value if min.nil? || value < min.not_nil!
          max = value if max.nil? || value > max.not_nil!
        end
        state.length += count
        state.sum = sum
        state.min = min
        state.max = max
        state
      end

      def merge(left : State, right : State) : State
        left.length += right.length
        left.sum += right.sum
        if min = right.min
          left.min = min if left.min.nil? || min < left.min.not_nil!
        end
        if max = right.max
          left.max = max if left.max.nil? || max > left.max.not_nil!
        end
        left
      end
    end

    class Sum < Basic
      def finish(state : State) : Int64
        state.sum
      end
    end

    class Mean < Basic
      def finish(state : State) : Float64?
        return nil if state.length == 0
        state.sum.to_f64 / state.length
      end
    end

    class MinMax < Basic
      def finish(state : State) : Tuple(Int32, Int32)?
        min = state.min
        max = state.max
        min && max ? {min, max} : nil
      end
    end

    class Summary < Basic
      def finish(state : State) : D4::Summary
        D4::Summary.new(state.length, state.sum, state.min, state.max)
      end
    end
  end

  class Track
    def aggregate_region(region : Region, reducer : D) forall D
      aggregate_region(region, reducer, Slice(Int32).new(65_536))
    end

    def aggregate_region(region : Region, reducer : D, scratch : Slice(Int32)) forall D
      state = reducer.seed
      if reducer.is_a?(Reducers::Basic)
        scan_values(region, scratch) do |_, values, count|
          state = reducer.consume_values(state, values, count)
        end
        return reducer.finish(state)
      end
      have_value = false
      current = 0_i32
      left = region.start
      scan_values(region, scratch) do |position, values, count|
        count.times do |index|
          value = values[index]
          offset = position + index
          if have_value && current != value
            state = reducer.consume(state, left, offset, current)
            left = offset
          end
          current = value
          have_value = true
        end
      end
      state = reducer.consume(state, left, region.stop, current) if have_value
      reducer.finish(state)
    end

    def aggregate(regions : Enumerable(Region), reducer : D, *, workers : Int32 = 1) forall D
      raise ArgumentError.new("workers must be positive") if workers <= 0
      if workers > 1
        items = regions.to_a
        slots = Array(RegionResult(typeof(reducer.finish(reducer.seed)))?).new(items.size, nil)
        ParallelWork.run(items.size, workers) do |index, scratch|
          region = items[index]
          slots[index] = RegionResult.new(index, region, aggregate_region(region, reducer, scratch))
        end
        return slots.map(&.not_nil!)
      end
      result = Array(RegionResult(typeof(reducer.finish(reducer.seed)))).new
      scratch = Slice(Int32).new(65_536)
      regions.each_with_index do |region, index|
        result << RegionResult.new(index, region, aggregate_region(region, reducer, scratch))
      end
      result
    end

    def each_aggregate(regions : Enumerable(Region), reducer : D, *, workers : Int32 = 1,
                       batch_size : Int32 = 256, &block) forall D
      raise ArgumentError.new("batch_size must be positive") if batch_size <= 0
      raise ArgumentError.new("workers must be positive") if workers <= 0
      if workers > 1
        batch = Array(Region).new(batch_size)
        offset = 0
        regions.each do |region|
          batch << region
          if batch.size == batch_size
            aggregate(batch, reducer, workers: workers).each do |result|
              yield RegionResult.new(offset + result.index, result.region, result.value)
            end
            offset += batch.size
            batch.clear
          end
        end
        aggregate(batch, reducer, workers: workers).each do |result|
          yield RegionResult.new(offset + result.index, result.region, result.value)
        end
        return
      end
      scratch = Slice(Int32).new(65_536)
      regions.each_with_index do |region, index|
        yield RegionResult.new(index, region, aggregate_region(region, reducer, scratch))
      end
    end

    def each_aggregate(regions : Indexable(Region), reducer : D, *, workers : Int32 = 1,
                       batch_size : Int32 = 256) forall D
      raise ArgumentError.new("batch_size must be positive") if batch_size <= 0
      raise ArgumentError.new("workers must be positive") if workers <= 0
      AggregateIterator(D, typeof(reducer.finish(reducer.seed))).new(self, regions, reducer, workers, batch_size)
    end
  end

  class File
    def aggregate(regions : Enumerable(Region), reducer : D, *, workers : Int32 = 1) forall D
      default_track.aggregate(regions, reducer, workers: workers)
    end

    def each_aggregate(regions : Enumerable(Region), reducer : D, *, workers : Int32 = 1,
                       batch_size : Int32 = 256, &block) forall D
      default_track.each_aggregate(regions, reducer, workers: workers, batch_size: batch_size) { |result| yield result }
    end

    def each_aggregate(regions : Indexable(Region), reducer : D, *, workers : Int32 = 1,
                       batch_size : Int32 = 256) forall D
      default_track.each_aggregate(regions, reducer, workers: workers, batch_size: batch_size)
    end
  end

  class Matrix
    def aggregate(regions : Enumerable(Region), reducer : D, *, workers : Int32 = 1) forall D
      raise ArgumentError.new("workers must be positive") if workers <= 0
      if workers > 1
        items = regions.to_a
        slots = Array(RegionResult(Array(typeof(reducer.finish(reducer.seed))))?).new(items.size, nil)
        ParallelWork.run(items.size, workers) do |index, scratch|
          region = items[index]
          slots[index] = RegionResult.new(index, region, @tracks.map { |track| track.aggregate_region(region, reducer, scratch) })
        end
        return slots.map(&.not_nil!)
      end
      result = Array(RegionResult(Array(typeof(reducer.finish(reducer.seed))))).new
      scratch = Slice(Int32).new(65_536)
      regions.each_with_index do |region, index|
        values = @tracks.map { |track| track.aggregate_region(region, reducer, scratch) }
        result << RegionResult.new(index, region, values)
      end
      result
    end

    def aggregate_into(regions : Indexable(Region), reducer : D, output : Slice(R), *, workers : Int32 = 1) : Nil forall D, R
      raise ArgumentError.new("output size must match regions times columns") unless output.size.to_i64 == regions.size.to_i64 * column_count
      raise ArgumentError.new("workers must be positive") if workers <= 0
      if workers > 1
        ParallelWork.run(regions.size, workers) do |index, scratch|
          region = regions[index]
          @tracks.each_with_index do |track, column|
            output[index * column_count + column] = track.aggregate_region(region, reducer, scratch)
          end
        end
        return
      end
      scratch = Slice(Int32).new(65_536)
      regions.each_with_index do |region, index|
        @tracks.each_with_index do |track, column|
          output[index * column_count + column] = track.aggregate_region(region, reducer, scratch)
        end
      end
    end
  end
end
