require "./spec_helper"

describe D4 do
  it "has a version number" do
    D4::VERSION.should_not be_nil
  end

  it "validates class-based genomic values" do
    interval = D4::RawInterval.new(100, 200, 42)
    interval.left.should eq(100_i64)
    interval.right.should eq(200_i64)
    interval.length.should eq(100_i64)
    interval.to_s.should eq("100-200:42")

    metadata = D4::Metadata.new(
      [D4::Chromosome.new("chr1", 1000)],
      D4::Dictionary.new(0, 128)
    )
    metadata.chromosome_size("chr1").should eq(1000_i64)
    metadata.has_chromosome?("chr2").should be_false
    D4::Region.new("chr1", 100...200).length.should eq(100_i64)
    D4::Region.new("chr1", 100..199).stop.should eq(200_i64)
  end

  it "rejects an invalid D4 magic number without native bindings" do
    source = D4::MemorySource.new(Bytes[0_u8, 1_u8, 2_u8, 3_u8, 0_u8, 0_u8, 0_u8, 0_u8])
    expect_raises(D4::FormatError, "invalid D4 file magic") { D4::File.open(source) }
  end

  it "reads an uncompressed D4 fixture produced by Rust d4-format" do
    path = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    D4.open(path) do |file|
      file.chromosome_size("chr").should eq(10_i64)
      file.values("chr").should eq([0, 0, 0, 1, 2, 2, 2, 1, 1, 0])
      file.query("chr").map(&.to_s).should eq(["0-3:0", "3-4:1", "4-7:2", "7-9:1", "9-10:0"])
    end
  end

  it "writes and reads a pure Crystal D4 file" do
    path = File.join(Dir.tempdir, "d4-crystal-roundtrip-#{Random.rand(1_000_000)}.d4")
    begin
      D4.writer(path) do |writer|
        writer.set_chromosomes({"chr1" => 12_u32, "chr2" => 5_u32})
        writer.write_values("chr1", 0, [1_i32, 1_i32, 2_i32, 2_i32, 150_i32])
        writer.write_intervals("chr1", [D4::RawInterval.new(7, 10, -3)])
        writer.write_dense_values("chr2", 1, [9_i32, 9_i32])
      end

      D4.open(path) do |file|
        file.track_names.should eq([""])
        file.values("chr1").should eq([1, 1, 2, 2, 150, 0, 0, -3, -3, -3, 0, 0])
        file.values("chr2").should eq([0, 9, 9, 0, 0])
        file.sum("chr1", 0, 10).should eq(147_i64)
        file.mean("chr1", 0, 10).should eq(14.7)
        file.query("chr1", 0, 10).map(&.to_s).should eq(["0-2:1", "2-4:2", "4-5:150", "5-7:0", "7-10:-3"])
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "uses caller-owned storage with read_values_into" do
    path = File.join(Dir.tempdir, "d4-crystal-buffer-#{Random.rand(1_000_000)}.d4")
    begin
      D4.writer(path) do |writer|
        writer.set_chromosomes({"chr1" => 4_u32})
        writer.write_values("chr1", 0, [4_i32, 5_i32, 6_i32, 7_i32])
      end
      D4.open(path) do |file|
        buffer = Slice(Int32).new(3)
        file.read_values_into("chr1", 1, buffer).should eq(3)
        buffer.should eq(Slice[5_i32, 6_i32, 7_i32])
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
