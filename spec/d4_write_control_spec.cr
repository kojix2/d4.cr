require "./spec_helper"
require "file_utils"

private def in_control_directory(&)
  directory = File.tempname("d4-write-control")
  Dir.mkdir(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

describe D4::WriteControl do
  it "rejects writes after cancellation and preserves an existing destination" do
    in_control_directory do |directory|
      path = File.join(directory, "existing.d4")
      File.write(path, "existing content")
      control = D4::WriteControl.new
      writer = D4.create(path, chromosomes: [D4::Chromosome.new("chr", 10)], control: control,
        options: D4::WriteOptions.new(overwrite: true))
      begin
        writer.write_value("chr", 0, 3)
        control.cancel
        expect_raises(D4::CancelledError) { writer.write_values("chr", 1, [4_i32, 5_i32]) }
        expect_raises(D4::CancelledError) { writer.write_value("chr", 1, 4) }
        expect_raises(D4::CancelledError) { writer.finish }
        writer.finished?.should be_false
        File.read(path).should eq("existing content")
        Dir.children(directory).should eq(["existing.d4"])
      ensure
        writer.abort
      end
    end
  end

  it "interrupts a lazy input during a write and removes its spools" do
    in_control_directory do |directory|
      control = D4::WriteControl.new
      consumed = 0
      values = (0...100_000).each.map do |index|
        consumed += 1
        control.cancel if index == 10
        1_i32
      end
      expect_raises(D4::CancelledError) do
        D4.create(File.join(directory, "cancelled.d4"),
          chromosomes: [D4::Chromosome.new("chr", 100_000)], control: control) do |writer|
          writer.write_values("chr", 0, values)
        end
      end
      consumed.should be < 100_000
      Dir.children(directory).should be_empty
    end
  end

  it "reports a consistent primary byte total, including buffered bytes" do
    in_control_directory do |directory|
      events = [] of D4::WriteProgress
      control = D4::WriteControl.new { |event| events << event }
      D4.create(File.join(directory, "complete.d4"),
        chromosomes: [D4::Chromosome.new("chr", 10)], control: control) { |_| }
      primary = events.select(&.stage.writing_primary?)
      primary.size.should be >= 2
      primary.first.total.should be > 0
      primary.map(&.total).uniq.size.should eq(1)
      primary.last.current.should eq(primary.last.total)
    end
  end
end
