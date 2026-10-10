require "./spec_helper"

describe "D4 format compatibility and lifecycle" do
  it "sums zero-width primary regions with raw and compressed secondary records" do
    [D4::Compression.none, D4::Compression.deflate].each do |compression|
      path = File.join(Dir.tempdir, "d4-crystal-constant-sum-#{Random.rand(1_000_000)}.d4")
      begin
        D4.create(path, chromosomes: [D4::Chromosome.new("chr", 140_000)],
          dictionary: D4::Dictionary.new([5_i32]), default_value: 5_i32,
          options: D4::WriteOptions.new(compression: compression, indexes: [D4::IndexKind::SecondaryFrames])) do |writer|
          writer.write_interval("chr", 100, 200, -7_i32)
          writer.write_interval("chr", 65_535, 65_540, 9_i32)
          writer.write_interval("chr", 129_999, 140_000, -3_i32)
        end
        D4.open(path) do |file|
          regions = [
            D4::Region.new("chr", 0, 140_000),
            D4::Region.new("chr", 150, 65_537),
            D4::Region.new("chr", 65_538, 130_001),
            D4::Region.new("chr", 140_000, 140_000),
          ]
          expected = regions.map { |region| file.values(region).sum(0_i64) }
          regions.map { |region| file.sum(region, index: D4::IndexPolicy::Scan) }.should eq(expected)
          file.aggregate(regions, D4::Reducers::Sum.new, workers: 2).map(&.value).should eq(expected)
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "packs dense range codes and fallbacks across chunk boundaries for several widths" do
    [1, 2, 3, 4, 7, 8, 9, 16, 24, 30].each do |width|
      path = File.join(Dir.tempdir, "d4-crystal-width-#{width}-#{Random.rand(1_000_000)}.d4")
      low = width == 3 ? -4_i32 : 0_i32
      values = Array(Int32).new(522, 0_i32)
      values.size.times do |position|
        next if position == 257 || position == 258
        values[position] = position == 7 || position == 260 ? low - 1 : low + (position % (1 << width)).to_i32
      end
      values[521] = low + ((1 << width) - 1).to_i32
      begin
        D4.create(path, chromosomes: [D4::Chromosome.new("chr", values.size.to_i64)],
          dictionary: D4::Dictionary.new(low, low + (1 << width).to_i32)) do |writer|
          writer.write_values("chr", 0, values[0, 257])
          writer.write_values("chr", 259, values[259, 263])
        end
        D4.open(path) do |file|
          file.values("chr").should eq(values)
          file.value("chr", 6).should eq(values[6])
          file.value("chr", 7).should eq(values[7])
          file.value("chr", 521).should eq(values[521])
        end
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  it "fills long packed gaps while preserving chromosome bit alignment" do
    path = File.join(Dir.tempdir, "d4-crystal-gap-#{Random.rand(1_000_000)}.d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("first", 73), D4::Chromosome.new("second", 1_000_003)],
        dictionary: D4::Dictionary.new(0_i32, 8_i32)) do |writer|
        writer.write_values("first", 1, [3_i32, 5_i32])
        writer.flush
        writer.write_interval("first", 70, 73, 7_i32)
        writer.write_value("second", 1_000_002, 7_i32)
      end
      D4.open(path) do |file|
        file.values("first", 0, 5).should eq([0, 3, 5, 0, 0])
        file.values("first", 69, 73).should eq([0, 7, 7, 7])
        file.value("second", 1_000_001).should eq(0)
        file.value("second", 1_000_002).should eq(7)
        file.sum("second").should eq(7_i64)
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "writes the final dictionary code without secondary records and bounds the mapped directory" do
    path = File.join(Dir.tempdir, "d4-crystal-dictionary-edge-#{Random.rand(1_000_000)}.d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 8)],
        dictionary: D4::Dictionary.new(0_i32, 8_i32)) do |writer|
        writer.write_values("chr", 0, [0_i32, 1_i32, 2_i32, 3_i32, 4_i32, 5_i32, 6_i32, 7_i32])
      end
      D4.open(path) do |file|
        root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
        secondary = root.entry(".stab", 1_u8)
        parts = D4::Format::Directory.open(file.source, secondary.offset, file.options.max_metadata_bytes)
        parts.entries.each do |entry|
          (entry.offset + entry.size).should be <= (secondary.offset + secondary.size)
        end
        stream = parts.entry("0", 0_u8)
        stream.size.should eq(16_i64)
        file.values("chr").should eq([0, 1, 2, 3, 4, 5, 6, 7])
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reads both raw and DEFLATE tracks in a Rust-produced container" do
    path = File.join(__DIR__, "fixtures", "rust-multitrack.d4")
    D4.open(path) do |file|
      file.track_names.should eq(["input", "input2"])
      expect_raises(D4::TrackSelectionError) { file.value("1", 10_000) }
      file.track("input2").values("1", 9_999, 10_003).should eq([0, 1, 1, 1])
      file.track("input2").summary("1").sum.should eq(5_000_i64)
      file.track("input").summary("1").sum.should eq(9_917_i64)
    end
  end

  it "lazily creates independent interval iterators and invalidates borrowed views on close" do
    path = File.join(__DIR__, "fixtures", "rust-multitrack.d4")
    file = D4.open(path)
    track = file.track("input2")
    first = track.each_interval("1")
    second = track.each_interval("1")
    first.next.to_s.should eq("0-10000:0")
    second.next.to_s.should eq("0-10000:0")
    first.next.to_s.should eq("10000-15000:1")
    file.close
    expect_raises(D4::ClosedError) { track.value("1", 10_000) }
    expect_raises(D4::ClosedError) { second.next }
  end

  it "writes K=0, mapped dictionaries, nonzero defaults and long secondary ranges" do
    path = File.join(Dir.tempdir, "d4-crystal-special-#{Random.rand(1_000_000)}.d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("zero", 140_000), D4::Chromosome.new("map", 10)],
        dictionary: D4::Dictionary.new([3_i32]), default_value: 9_i32) do |writer|
        writer.write_interval("zero", 65_535, 65_538, 3_i32)
        writer.write_interval("map", 2, 4, -5_i32)
      end
      D4.open(path) do |file|
        file.values("zero", 65_533, 65_540).should eq([9, 9, 3, 3, 3, 9, 9])
        file.value("zero", 139_999).should eq(9)
        file.values("map").should eq([9, 9, -5, -5, 9, 9, 9, 9, 9, 9])
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "does not publish a failed writer block or replace an existing destination" do
    path = File.join(Dir.tempdir, "d4-crystal-abort-#{Random.rand(1_000_000)}.d4")
    begin
      expect_raises(ArgumentError, "stop") do
        D4.writer(path) do |writer|
          writer.set_chromosomes({"chr" => 1_u32})
          raise ArgumentError.new("stop")
        end
      end
      File.exists?(path).should be_false
      File.write(path, "untouched")
      expect_raises(D4::Error, "destination already exists") do
        D4.writer(path) { |writer| writer.set_chromosomes({"chr" => 1_u32}) }
      end
      File.read(path).should eq("untouched")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "streams secondary records across linked frame boundaries" do
    path = File.join(Dir.tempdir, "d4-crystal-frames-#{Random.rand(1_000_000)}.d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 13_200)],
        dictionary: D4::Dictionary.new([0_i32])) do |writer|
        13_200.times { |i| writer.write_value("chr", i, i.even? ? 4_i32 : 5_i32) }
      end
      D4.open(path) do |file|
        file.value("chr", 6_552).should eq(4)
        file.value("chr", 6_553).should eq(5)
        file.value("chr", 13_199).should eq(5)
        file.summary("chr").sum.should eq(59_400_i64)
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "counts bases in histograms and coverage, including tails and negative values" do
    path = File.join(__DIR__, "fixtures", "rust-multitrack.d4")
    D4.open(path, track: "input") do |file|
      region = D4::Region.new("1", 9_998, 10_003)
      histogram = file.histogram(region, value_range: -1_i32...50_i32)
      histogram.counts[1].should eq(0_i64)
      histogram.counts[7].should eq(1_i64)
      histogram.counts[11].should eq(1_i64)
      histogram.above.should eq(2_i64)
      expect_raises(D4::IncompleteHistogramError) { histogram.quantile(0.5) }
      exact = file.exact_histogram(region)
      exact.quantile(0.5).should eq(38)
      expect_raises(D4::AllocationLimitError) { file.exact_histogram(region, max_values: 2) }
      coverage = file.coverage(region, thresholds: [0_i32, 50_i32, 100_i32])
      coverage.counts.should eq([5_i64, 2_i64, 0_i64])
      coverage.fraction(1).should eq(0.4)
      counts = Slice(Int64).new(3)
      file.coverage_into(region, Slice[0_i32, 50_i32, 100_i32], counts).should eq(5_i64)
      counts.should eq(Slice[5_i64, 2_i64, 0_i64])
    end
  end

  it "applies denominator only through the explicit scaled view" do
    path = File.join(Dir.tempdir, "d4-crystal-scaled-#{Random.rand(1_000_000)}.d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 4)], denominator: 2.0) do |writer|
        writer.write_values("chr", 0, [1_i32, 2_i32, -3_i32, 0_i32])
      end
      D4.open(path) do |file|
        file.values("chr").should eq([1, 2, -3, 0])
        file.scaled.values("chr").should eq([0.5, 1.0, -1.5, 0.0])
        file.scaled.each_interval("chr").next.as(D4::ScaledInterval).value.should eq(0.5)
        file.scaled.mean("chr").should eq(0.0)
        file.scaled.minmax("chr").should eq({-1.5, 1.0})
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "reads multiple tracks in caller-owned row-major buffers" do
    path = File.join(__DIR__, "fixtures", "rust-multitrack.d4")
    D4.open(path) do |file|
      matrix = file.matrix(["input2", "input"])
      matrix.track_names.should eq(["input2", "input"])
      output = Slice(Int32).new(8)
      matrix.read_rows_into("1", 9_999, output).should eq(4)
      output.should eq(Slice[0_i32, 10_i32, 1_i32, 38_i32, 1_i32, 55_i32, 1_i32, 72_i32])
      blocks = Array(Int32).new
      matrix.scan_rows(D4::Region.new("1", 9_999, 10_004), output) do |_start, values, count|
        count.times { |row| blocks << values[row * 2] }
      end
      blocks.should eq([0, 1, 1, 1, 1])
      scaled = Slice(Float64).new(4)
      matrix.scaled.read_rows_into("1", 10_000, scaled).should eq(2)
      scaled.should eq(Slice[1.0, 38.0, 1.0, 55.0])
    end
  end

  it "borrows seekable IO without closing it by default" do
    bytes = File.read(File.join(__DIR__, "fixtures", "rust-input-10nt.d4")).to_slice
    io = IO::Memory.new(bytes)
    D4.open(io) { |file| file.value("chr", 4).should eq(2) }
    io.closed?.should be_false
    io.rewind
    D4.open(io, sync_close: true) { |file| file.value("chr", 3).should eq(1) }
    io.closed?.should be_true
  end

  it "matches an independent dense reference across gaps, fallback codes and negative values" do
    path = File.join(Dir.tempdir, "d4-crystal-reference-#{Random.rand(1_000_000)}.d4")
    expected = Array(Int32).new(4_097) do |position|
      if position % 13 < 5
        -7_i32
      elsif position % 17 < 3
        3_i32
      elsif position % 11 == 0
        2_i32
      else
        9_i32
      end
    end
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", expected.size.to_i64)],
        dictionary: D4::Dictionary.new([9_i32, 3_i32, 2_i32, -7_i32]), default_value: 9_i32) do |writer|
        writer.write_values("chr", 0, expected)
      end
      D4.open(path) do |file|
        (0...expected.size).step(127) do |start|
          stop = Math.min(expected.size, start + 199)
          region_values = expected[start...stop]
          file.values("chr", start, stop).should eq(region_values)
          file.sum("chr", start, stop).should eq(region_values.sum(0_i64))
        end
        region = D4::Region.new("chr", 0, expected.size.to_i64)
        histogram = file.exact_histogram(region)
        expected.uniq.each do |value|
          histogram.counts[value].should eq(expected.count(value).to_i64)
        end
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "accepts the Rust first-frame raw fallback in a padded compressed stream" do
    frame = Bytes.new(512)
    frame[16] = 1_u8  # The first DEFLATE frame fell back to raw records.
    frame[25] = 1_u8  # Record count in the compressed-frame header.
    frame[29] = 1_u8  # Record left + 1.
    frame[35] = 42_u8 # Record value.
    source = D4::MemorySource.new(frame)
    entry = D4::Format::Entry.new(0_u8, 0_i64, 512_i64, "0")
    cursor = D4::SecondaryRecordIterator.new(source, [entry], true,
      D4::Region.new("chr", 0, 1), 1024_i64)
    record = cursor.next_record.not_nil!
    {record.left, record.right, record.value}.should eq({0_i64, 1_i64, 42_i32})
    cursor.next_record.should be_nil
  end

  it "quantizes explicitly and rejects non-finite or overflowing scaled input" do
    path = File.join(Dir.tempdir, "d4-crystal-quantized-#{Random.rand(1_000_000)}.d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 4)], denominator: 2.0) do |writer|
        writer.write_scaled_values("chr", 0, [0.25, -0.25, 1.25], rounding: D4::Rounding::NearestAway)
        expect_raises(ArgumentError) do
          writer.write_scaled_interval("chr", 3, 4, Float64::NAN, rounding: D4::Rounding::Floor)
        end
        expect_raises(ArgumentError) do
          writer.write_scaled_interval("chr", 3, 4, 1e30, rounding: D4::Rounding::Floor)
        end
      end
      D4.open(path) { |file| file.values("chr").should eq([1, -1, 3, 0]) }
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "writes DEFLATE secondary streams with linked frames and reads them back" do
    path = File.join(Dir.tempdir, "d4-crystal-deflate-#{Random.rand(1_000_000)}.d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 15_000)],
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(compression: D4::Compression.deflate(level: 5))) do |writer|
        15_000.times { |i| writer.write_value("chr", i, (i % 97).to_i32 + 1) }
      end
      D4.open(path) do |file|
        file.value("chr", 0).should eq(1)
        file.value("chr", 47).should eq(48)
        file.value("chr", 6_554).should eq(56)
        file.value("chr", 14_999).should eq(62)
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "produces weighted fixed-size and evenly sampled bins" do
    path = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    D4.open(path) do |file|
      region = D4::Region.new("chr", 0, 10)
      bins = Array(D4::BinSummary).new
      file.each_bin(region, bin_size: 4) { |bin| bins << bin }
      bins.map(&.length).should eq([4_i64, 4_i64, 2_i64])
      bins.map(&.sum).should eq([1_i64, 7_i64, 1_i64])
      sample = file.sample(region, bins: 3)
      sample.map(&.length).should eq([4_i64, 3_i64, 3_i64])
      sample.sum(0_i64, &.sum).should eq(file.sum("chr"))
      file.sample(D4::Region.new("chr", 5, 5)).should be_empty
      expect_raises(ArgumentError) { file.each_bin(region, bin_size: 0) }
    end
  end

  it "aggregates regions with typed reducers in input order" do
    path = File.join(__DIR__, "fixtures", "rust-multitrack.d4")
    D4.open(path) do |file|
      regions = [D4::Region.new("1", 10_000, 10_002), D4::Region.new("1", 0, 2)]
      track = file.track("input2")
      track.aggregate(regions, D4::Reducers::Sum.new).map(&.value).should eq([2_i64, 0_i64])
      track.aggregate(regions, D4::Reducers::Mean.new).map(&.value).should eq([1.0, 0.0])
      file.matrix(["input", "input2"]).aggregate(regions, D4::Reducers::Sum.new).first.value.should eq([93_i64, 2_i64])
      streamed = Array(Int64).new
      track.each_aggregate(regions, D4::Reducers::Sum.new) { |result| streamed << result.value }
      streamed.should eq([2_i64, 0_i64])
      iterator = track.each_aggregate(regions, D4::Reducers::Sum.new)
      iterator.next.as(D4::RegionResult(Int64)).value.should eq(2_i64)
      matrix_output = Slice(Int64).new(4)
      file.matrix(["input", "input2"]).aggregate_into(regions, D4::Reducers::Sum.new, matrix_output)
      matrix_output.should eq(Slice[93_i64, 2_i64, 0_i64, 0_i64])
      track.aggregate(regions, D4::Reducers::Sum.new, workers: 2).map(&.value).should eq([2_i64, 0_i64])
      parallel_streamed = [] of Int64
      track.each_aggregate(regions, D4::Reducers::Sum.new, workers: 2, batch_size: 1) do |result|
        parallel_streamed << result.value
      end
      parallel_streamed.should eq([2_i64, 0_i64])
      parallel_iterator = track.each_aggregate(regions, D4::Reducers::Sum.new, workers: 2, batch_size: 1)
      parallel_iterator.to_a.map(&.value).should eq([2_i64, 0_i64])
      matrix = file.matrix(["input", "input2"])
      matrix.aggregate(regions, D4::Reducers::Sum.new, workers: 2).map(&.value).should eq([[93_i64, 2_i64], [0_i64, 0_i64]])
      matrix.aggregate_into(regions, D4::Reducers::Sum.new, matrix_output, workers: 2)
      matrix_output.should eq(Slice[93_i64, 2_i64, 0_i64, 0_i64])
      expect_raises(D4::UnknownChromosomeError) do
        track.aggregate([regions[0], D4::Region.new("missing", 0, 1)], D4::Reducers::Sum.new, workers: 2)
      end
    end
  end
end
