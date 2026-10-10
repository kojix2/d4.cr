require "spec"
require "../src/d4_plot/annotation"

describe D4Plot::AnnotationIndex do
  it "converts BED half-open intervals and keeps GFF/GTF coordinates inclusive" do
    bed = D4Plot::AnnotationIndex.parse_line("chr1\t0\t1\tone base\t0\t-").as(D4Plot::AnnotationFeature)
    {bed.start1, bed.end1, bed.strand}.should eq({1_u32, 1_u32, "-"})
    gtf = D4Plot::AnnotationIndex.parse_line("chr1\tref\texon\t1\t1\t.\t+\t.\tgene_name \"A\";").as(D4Plot::AnnotationFeature)
    {gtf.start1, gtf.end1, gtf.name}.should eq({1_u32, 1_u32, "A"})
    D4Plot::AnnotationIndex.parse_line("chr1\t1\t1").should be_nil
    D4Plot::AnnotationIndex.parse_line("chr1\tref\tgene\t0\t10\t.\t+\t.\tID=A").should be_nil
  end

  it "reports chromosome mismatches and includes boundary overlaps" do
    feature = D4Plot::AnnotationFeature.new("chr1", 10_u32, 20_u32, "gene", "A", "+")
    index = D4Plot::AnnotationIndex.new("test.gff", [feature])
    index.overlapping(D4Plot::Region.new("chr1", 20_u32, 20_u32), 10).size.should eq(1)
    index.overlapping(D4Plot::Region.new("chr1", 21_u32, 21_u32), 10).should be_empty
    index.track_for(D4Plot::Region.new("1", 1_u32, 20_u32), 100_u32, 10).notice.as(String).should contain("names must match")
    index.track_for(D4Plot::Region.new("chr1", 21_u32, 30_u32), 100_u32, 10).notice.should eq("No overlapping annotations in this region")
  end
end

# Optional integration coverage for the external tabix reader.
if Process.find_executable("tabix") && Process.find_executable("bgzip")
  describe "Indexed annotations" do
    it "streams indexed BED records and stops at the feature limit" do
      path = File.tempname("d4-plot-annotation", ".bed")
      begin
        File.write(path, "chr1\t0\t10\tA\t0\t+\nchr1\t0\t20\tB\t0\t-\nchr1\t1\t30\tC\t0\t+\n")
        File.open("#{path}.gz", "w") do |file|
          Process.run("bgzip", {"-c", path}, output: file).success?.should be_true
        end
        Process.run("tabix", {"-p", "bed", "#{path}.gz"}).success?.should be_true
        region = D4Plot::Region.new("chr1", 1_u32, 30_u32)
        plain = D4Plot::AnnotationIndex.load(path)
        indexed = D4Plot::AnnotationIndex.load("#{path}.gz")
        indexed.overlapping(region, 10).should eq(plain.overlapping(region, 10))
        indexed.track_for(region, 100_u32, 1).notice.should eq("Too many annotations (>1); zoom in")
      ensure
        [path, "#{path}.gz", "#{path}.gz.tbi"].each { |file| File.delete(file) if File.exists?(file) }
      end
    end
  end
end
