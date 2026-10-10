require "spec"
require "../src/d4_plot/data_sampler"

describe D4Plot::DataSampler do
  it "samples the displayed bins from a Rust-generated D4 file" do
    path = File.join(__DIR__, "../../../spec/fixtures/rust-input-10nt.d4")
    D4.open(path) do |file|
      points = D4Plot::DataSampler.downsample(file, "chr", 0_u32, 10_u32, 4)
      points.should eq([{2_u32, 0.0}, {5_u32, 5.0 / 3}, {7_u32, 1.5}, {9_u32, 0.5}])
      D4Plot::DataSampler.downsample(file, "chr", 3_u32, 7_u32, 256).should eq(
        [{4_u32, 1.0}, {5_u32, 2.0}, {6_u32, 2.0}, {7_u32, 2.0}])
      [{0_u32, 10_u32, 3}, {2_u32, 9_u32, 4}, {3_u32, 10_u32, 2}].each do |start0, end0, count|
        expected = file.sample(D4::Region.new("chr", start0, end0), bins: count).map do |bin|
          {((bin.start + bin.stop - 1) // 2 + 1).to_u32, bin.sum.to_f64 / bin.length}
        end
        D4Plot::DataSampler.downsample(file, "chr", start0, end0, count).should eq(expected)
      end
    end
  end
end
