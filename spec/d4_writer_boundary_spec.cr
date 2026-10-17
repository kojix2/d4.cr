require "./spec_helper"

describe "D4 writer coordinate boundaries" do
  it "rejects overflowing positions without advancing writer state" do
    temporary = File.tempfile("d4-writer-boundary", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    writer = D4.create(path,
      chromosomes: [D4::Chromosome.new("chr", 2_i64)],
      dictionary: D4::Dictionary.new(0_i32, 2_i32))
    begin
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", Int64::MAX, [1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", Int64::MAX, [1_i32].each)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", Int64::MAX, [1.0_f64].each, rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_interval("chr", Int64::MAX, Int64::MAX, 1_i32)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_interval("chr", Int64::MAX, Int64::MAX, 1.0_f64, rounding: D4::Rounding::Floor)
      end
      # Array-like input has a known count, so reject the entire range before
      # it can advance the primary/secondary writer state.
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", 1, [1_i32, 1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", 1, Slice[1_i32, 1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_dense_values("chr", 1, [1_i32, 1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", 1, [1.0_f64, 1.0_f64], rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", 1, Slice[1.0_f64, 1.0_f64], rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /scaled value must be finite/) do
        writer.write_scaled_values("chr", 0, [1.0_f64, Float64::NAN], rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", UInt64::MAX, [1_i32])
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_values("chr", UInt64::MAX, [1_i32].each)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", UInt64::MAX, [1.0_f64].each, rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_interval("chr", UInt64::MAX, UInt64::MAX, 1_i32)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_interval("chr", 0, UInt64::MAX, 1_i32)
      end
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_interval("chr", UInt64::MAX, UInt64::MAX, 1.0_f64, rounding: D4::Rounding::Floor)
      end
      expect_raises(ArgumentError, /invalid point coordinate/) do
        writer.write_value("chr", UInt64::MAX, 1_i32)
      end

      writer.write_values("chr", 0, [1_i32]).should eq(1)
      writer.write_values("chr", 1, [1_i32]).should eq(1)
      writer.write_values("chr", 2, [] of Int32).should eq(0)
      writer.write_values("chr", 2, ([] of Int32).each).should eq(0)
      writer.write_scaled_values("chr", 2, ([] of Float64).each, rounding: D4::Rounding::Floor).should eq(0)
      expect_raises(ArgumentError, /invalid write range/) { writer.write_values("chr", -1, [] of Int32) }
      expect_raises(ArgumentError, /invalid write range/) { writer.write_values("chr", -1, ([] of Int32).each) }
      expect_raises(ArgumentError, /invalid write range/) do
        writer.write_scaled_values("chr", -1, ([] of Float64).each, rounding: D4::Rounding::Floor)
      end
      writer.finish

      D4.open(path, &.values("chr").should(eq([1_i32, 1_i32])))
    ensure
      writer.abort unless writer.closed?
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects frame payload sizes that cannot be represented safely" do
    D4::FrameEncoder.size_for(0).should eq(D4::Format::DIRECTORY_FRAME_SIZE.to_i64)
    D4::FrameEncoder.exact_size_for(0).should eq(D4::Format::FRAME_HEADER_SIZE.to_i64)
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.size_for(-1) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.size_for(UInt64::MAX) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.size_for(Int64::MAX) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.exact_size_for(UInt64::MAX) }
    expect_raises(ArgumentError, /frame payload size/) { D4::FrameEncoder.exact_size_for(Int64::MAX) }
  end
end
