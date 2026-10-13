module D4
  # Long-running stages involved in materializing a D4 file or its indexes.
  enum WriteStage
    Finalizing
    WritingPrimary
    WritingSecondary
    BuildingIndexes
    Publishing
  end

  # A progress snapshot emitted by `WriteControl`.
  record WriteProgress,
    stage : WriteStage,
    chromosome : String? = nil,
    current : Int64 = 0_i64,
    total : Int64 = 0_i64

  # Coordinates progress reporting and cooperative cancellation for D4 writes.
  #
  # A control may be cancelled from another fiber or thread. Callbacks run in
  # the fiber performing the write and should return quickly.
  class WriteControl
    @cancelled = Atomic(Bool).new(false)

    def initialize(@on_progress : Proc(WriteProgress, Nil)? = nil)
    end

    def initialize(&@on_progress : WriteProgress -> Nil)
    end

    # Requests cancellation. The operation stops at its next checkpoint.
    def cancel : Nil
      @cancelled.set(true)
    end

    def cancelled? : Bool
      @cancelled.get
    end

    # Raises `CancelledError` when cancellation has been requested.
    def check! : Nil
      raise CancelledError.new("D4 operation was cancelled") if cancelled?
    end

    # Emits a progress snapshot after checking for cancellation.
    def update(progress : WriteProgress) : Nil
      check!
      @on_progress.try(&.call(progress))
      check!
    end
  end
end
