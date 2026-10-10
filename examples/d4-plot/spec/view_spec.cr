require "spec"
require "../src/d4_plot/view"
require "../src/d4_plot/plot_geometry"
require "../src/d4_plot/plot_settings"

private def chromosomes
  {"chr1" => 1_000_000_u32}
end

describe D4Plot::Region do
  it "accepts pasted coordinates, a single base, and a whole chromosome" do
    D4Plot::Region.resolve(" chr1:1,234 - 5,678 ", chromosomes).should eq(D4Plot::Region.new("chr1", 1234_u32, 5678_u32))
    D4Plot::Region.resolve("chr1:10", chromosomes).length.should eq(1)
    D4Plot::Region.resolve("chr1", chromosomes).length.should eq(1_000_000)
  end

  it "rejects malformed, unknown and out-of-bounds regions" do
    ["chr1:0-10", "chr1:10-1", "chr1:1-1000001", "chr1:12,34-5678", "1:1-10", "chr1:4294967296"].each do |text|
      expect_raises(ArgumentError) { D4Plot::Region.resolve(text, chromosomes) }
    end
  end

  it "keeps navigation inside chromosome boundaries while retaining its span" do
    D4Plot::Region.bounded("chr1", -20_i64, 10_i64, 100_u32).to_s.should eq("chr1:1-10")
    D4Plot::Region.bounded("chr1", 95_i64, 10_i64, 100_u32).to_s.should eq("chr1:91-100")
    D4Plot::Region.bounded("chr1", 20_i64, 1000_i64, 100_u32).to_s.should eq("chr1:1-100")
  end
end

describe D4Plot::SampledView do
  it "uses exact bin boundaries for inspection, weighted means and bedGraph export" do
    region = D4Plot::Region.new("chr", 11_u32, 20_u32)
    view = D4Plot::SampledView.new(region, [{12_u32, 2.0}, {15_u32, 4.0}, {17_u32, 8.0}, {19_u32, 10.0}])
    (0...4).map { |index| view.bin_edges(index) }.should eq([{10_i64, 13_i64}, {13_i64, 16_i64}, {16_i64, 18_i64}, {18_i64, 20_i64}])
    [0.0, 0.299, 0.3, 0.6, 0.8, 1.0].map { |fraction| view.bin_at(fraction) }.should eq([0, 0, 1, 2, 3, 3])
    view.mean.should eq(5.4)
    io = IO::Memory.new
    view.write_bedgraph(io)
    io.to_s.lines.reject(&.starts_with?("#")).should eq(["chr\t10\t13\t2.0", "chr\t13\t16\t4.0", "chr\t16\t18\t8.0", "chr\t18\t20\t10.0"])
  end

  it "renders a one-base region with a full-width bin" do
    region = D4Plot::Region.new("chr", 7_u32, 7_u32)
    view = D4Plot::SampledView.new(region, [{7_u32, 3.0}])
    layout = D4Plot::PlotGeometry.new(800.0, 500.0, 0.0)
    layout.x_for(6_i64, region).should eq(layout.left)
    layout.x_for(7_i64, region).should eq(layout.left + layout.width)
    view.bin_at(1.0).should eq(0)
    view.resolution.should eq("1 bp / bin")
  end
end

describe D4Plot::PlotSettings do
  it "keeps negative signal visible when including zero in automatic scaling" do
    settings = D4Plot::PlotSettings.new
    low, high = settings.y_range(-10.0, -2.0)
    low.should be < -10.0
    high.should be > 0.0
    settings.y_min = -20.0
    settings.y_max = 20.0
    settings.y_range(-10.0, -2.0).should eq({-20.0, 20.0})
  end
end

describe D4Plot::ViewHistory do
  it "restores visited regions and discards forward history after a new navigation" do
    history = D4Plot::ViewHistory.new
    first = D4Plot::Region.new("chr", 1_u32, 100_u32)
    second = D4Plot::Region.new("chr", 10_u32, 20_u32)
    third = D4Plot::Region.new("chr", 30_u32, 40_u32)
    history.record(first)
    history.record(second)
    history.record(second)
    history.back.should eq(first)
    history.back.should be_nil
    history.forward.should eq(second)
    history.back.should eq(first)
    history.record(third)
    history.forward.should be_nil
    history.back.should eq(first)
  end
end
