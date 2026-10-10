require "./view"
require "./annotation"

module D4Plot
  record ViewRequest, id : Int32, path : String, track : String, region : Region,
    bins : Int32, use_index : Bool, annotation_path : String?, annotation_limit : Int32

  record ViewResult, request : ViewRequest, view : SampledView?, annotation_track : AnnotationTrack?,
    elapsed_ms : Float64, error : String?

  # One worker owns its file handles. Only the latest pending request/result is
  # retained, so rapid navigation cannot accumulate work or large allocations.
  class ViewLoader
    # Native synchronization avoids yielding the GUI fiber into Crystal's
    # scheduler while libui owns the main thread's event loop.
    @mutex = Thread::Mutex.new
    @wake = Thread::ConditionVariable.new
    @pending : ViewRequest?
    @result : ViewResult?
    @closed = false
    @generation = Atomic(Int32).new(0)
    @worker : Fiber::ExecutionContext::Isolated
    @file : D4::File?
    @file_path : String?
    @annotation_index : AnnotationIndex?

    def initialize
      @worker = Fiber::ExecutionContext::Isolated.new("d4-plot-reader") { work }
    end

    def submit(path, track, region, bins, use_index, annotation_path, annotation_limit) : Int32
      id = @generation.add(1) + 1
      @mutex.synchronize do
        raise "Viewer is closed" if @closed
        @pending = ViewRequest.new(id, path, track, region, bins, use_index, annotation_path, annotation_limit)
        @wake.signal
      end
      id
    end

    def poll : ViewResult?
      @mutex.synchronize do
        result = @result
        @result = nil
        result
      end
    end

    def cancel : Nil
      @generation.add(1)
      @mutex.synchronize do
        @pending = nil
        @result = nil
      end
    end

    def close : Nil
      @generation.add(1)
      @mutex.synchronize do
        @closed = true
        @pending = nil
        @wake.signal
      end
    end

    def wait : Nil
      @worker.wait
    end

    private def work : Nil
      while request = next_request
        next unless request.id == @generation.get
        started = Time.instant
        begin
          current_file = file_for(request.path)
          cancelled = -> { request.id != @generation.get }
          points = DataSampler.downsample(current_file.track(request.track), request.region, request.bins, request.use_index, cancelled)
          track = annotation_for(request)
          result = ViewResult.new(request, SampledView.new(request.region, points), track, (Time.instant - started).total_milliseconds, nil)
        rescue SamplingCancelled
          next
        rescue ex
          result = ViewResult.new(request, nil, nil, (Time.instant - started).total_milliseconds, ex.message || ex.class.name)
        end
        next unless request.id == @generation.get
        @mutex.synchronize do
          @result = result unless @closed
        end
      end
    ensure
      @file.try(&.close)
    end

    private def next_request : ViewRequest?
      @mutex.synchronize do
        while @pending.nil? && !@closed
          @wake.wait(@mutex)
        end
        request = @pending
        @pending = nil
        request
      end
    end

    private def file_for(path : String) : D4::File
      if file = @file
        return file if @file_path == path
      end
      opened = D4.open(path)
      @file.try(&.close)
      @file = opened
      @file_path = path
      opened
    end

    private def annotation_for(request : ViewRequest) : AnnotationTrack?
      unless path = request.annotation_path
        @annotation_index = nil
        return
      end
      @annotation_index = AnnotationIndex.load(path) if @annotation_index.try(&.path) != path
      @annotation_index.try(&.track_for(request.region, 5_000_000_u32, request.annotation_limit))
    rescue ex
      AnnotationTrack.notice("Annotation error: #{ex.message}")
    end
  end
end
