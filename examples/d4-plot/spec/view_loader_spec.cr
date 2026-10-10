require "spec"
require "../src/d4_plot/view_loader"

private def await_view(loader, id)
  deadline = Time.instant + 5.seconds
  loop do
    if result = loader.poll
      return result if result.request.id == id
    end
    raise "Timed out waiting for view" if Time.instant >= deadline
    sleep 1.millisecond
  end
end

describe D4Plot::ViewLoader do
  it "recovers from read errors and returns the latest requested region" do
    loader = D4Plot::ViewLoader.new
    begin
      region = D4Plot::Region.new("chr", 1_u32, 10_u32)
      id = loader.submit("/missing/d4-plot-test.d4", "", region, 4, true, nil, 100)
      await_view(loader, id).error.should_not be_nil
      path = File.join(__DIR__, "../../../spec/fixtures/rust-input-10nt.d4")
      loader.submit(path, "", region, 4, true, nil, 100)
      latest = D4Plot::Region.new("chr", 4_u32, 7_u32)
      id = loader.submit(path, "", latest, 256, true, nil, 100)
      result = await_view(loader, id)
      result.error.should be_nil
      view = result.view.as(D4Plot::SampledView)
      view.region.should eq(latest)
      view.points.should eq([{4_u32, 1.0}, {5_u32, 2.0}, {6_u32, 2.0}, {7_u32, 2.0}])
      loader.cancel
    ensure
      loader.close
      loader.wait
    end
  end
end
