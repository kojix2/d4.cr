require "./spec_helper"

class CancellationAwareD4Source < D4::MemorySource
  getter reads_while_armed : Int32

  def initialize(data : Bytes)
    super(data)
    @armed = false
    @reads_while_armed = 0_i32
  end

  def arm! : Nil
    @armed = true
  end

  def cancellation_requested? : Bool
    @reads_while_armed > 0
  end

  def read_at(offset : Int64, buffer : Bytes) : Int32
    count = super
    @reads_while_armed += 1 if @armed && count > 0
    count
  end
end

describe "cooperative read cancellation" do
  it "exposes the optional sum-index granularity" do
    indexed = File.join(__DIR__, "fixtures", "rust-indexed-sparse-100k.d4")
    unindexed = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")

    D4.open(indexed) do |file|
      granularity = file.default_track.sum_index_granularity || raise "sum-index granularity is unavailable"
      granularity.should be > 0_i64
      file.sum_index_granularity.should eq(granularity)
    end

    D4.open(unindexed) do |file|
      file.default_track.sum_index_granularity.should be_nil
      file.sum_index_granularity.should be_nil
    end
  end

  it "checks cancellation after yielding a scan block" do
    path = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    D4.open(path) do |file|
      cancelled = false
      blocks = 0
      expect_raises(D4::CancelledError) do
        file.default_track.scan_values("chr", Slice(Int32).new(4), cancelled: -> { cancelled }) do |_start, _values, _count|
          blocks += 1
          cancelled = true
        end
      end
      blocks.should eq(1)
    end
  end

  it "checks cancellation after a sum-index I/O chunk" do
    temporary = File.tempfile("d4-read-cancellation", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 131_072_i64)],
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::Sum])) { |_| }

      source = CancellationAwareD4Source.new(File.read(path).to_slice)
      file = D4.open(source, sync_close: true)
      begin
        source.arm!
        expect_raises(D4::CancelledError) do
          file.default_track.sum("chr", 0, 131_072, index: D4::IndexPolicy::Require,
            cancelled: -> { source.cancellation_requested? })
        end
        source.reads_while_armed.should be > 0
      ensure
        file.close
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "forwards a cancellation callback through File#sum" do
    path = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    D4.open(path) do |file|
      expect_raises(D4::CancelledError) do
        file.sum("chr", cancelled: -> { true })
      end
      expect_raises(D4::CancelledError) do
        file.sum(D4::Region.new("chr", 0_i64, 10_i64), cancelled: -> { true })
      end
    end
  end

  it "preserves ordinary sum results when cancellation remains false" do
    path = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    D4.open(path) do |file|
      track = file.default_track
      expected = track.sum("chr", 0, 10, index: D4::IndexPolicy::Scan)
      track.sum("chr", 0, 10, index: D4::IndexPolicy::Scan, cancelled: -> { false }).should eq(expected)
    end
  end
end
