require "spec"
require "../examples/d4-plot/src/d4_plot/data_sampler"

describe D4Plot::DataSampler do
  it "renders one-based bin centers and streamed means from a Rust-generated D4" do
    D4.open(File.join(__DIR__, "fixtures", "rust-input-10nt.d4")) do |file|
      region = D4Plot::Region.new("chr", 1_u32, 10_u32)
      D4Plot::DataSampler.downsample(file, region, 3).should eq([
        {2_u32, 0.25}, {6_u32, 2.0}, {9_u32, 2.0 / 3.0},
      ])
    end
  end

  it "uses the embedded sum index for large plot bins" do
    temporary = File.tempfile("d4-plot-index", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 1_000_000_i64)],
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum])) do |writer|
        writer.write_interval("chr", 500_000, 500_100, 2_i32)
      end
      D4.open(path) do |file|
        D4Plot::DataSampler.downsample(file, D4Plot::Region.new("chr", 1_u32, 1_000_000_u32), 2).should eq([
          {250_000_u32, 0.0}, {750_000_u32, 200.0 / 500_000},
        ])
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
