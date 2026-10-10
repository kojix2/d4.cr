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

describe D4Plot::DataSampler do
  it "applies the D4 denominator without hiding negative signal" do
    path = File.tempname("d4-plot-scaled", ".d4")
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 4)], denominator: 2.0) do |writer|
        writer.write_values("chr", 0, [2_i32, 4_i32, -6_i32, 0_i32])
      end
      D4.open(path) do |file|
        D4Plot::DataSampler.downsample(file, "chr", 0_u32, 4_u32, 2).should eq([{1_u32, 1.5}, {3_u32, -1.5}])
        expect_raises(ArgumentError) { D4Plot::DataSampler.downsample(file, "chr", 0_u32, 5_u32) }
        expect_raises(D4Plot::SamplingCancelled) do
          D4Plot::DataSampler.downsample(file, "chr", 0_u32, 4_u32, 2, false, -> { true })
        end
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "samples a selected track from a multi-track file" do
    D4.open(File.join(__DIR__, "../../../spec/fixtures/rust-multitrack.d4")) do |file|
      file.track_names.each do |name|
        track = file.track(name)
        chromosome = track.chromosomes.first
        region = D4::Region.new(chromosome.name, 0_i64, chromosome.size)
        expected = track.sample(region, bins: 4).map do |bin|
          {((bin.start + bin.stop - 1) // 2 + 1).to_u32, bin.sum.to_f64 / bin.length / track.metadata.denominator}
        end
        D4Plot::DataSampler.downsample(track, chromosome.name, 0_u32, chromosome.size.to_u32, 4).should eq(expected)
      end
    end
  end
end
