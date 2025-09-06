require "./spec_helper"

describe D4 do
  describe "VERSION" do
    it "has a version number" do
      D4::VERSION.should_not be_nil
    end
  end

  describe "Interval" do
    it "creates an interval with correct properties" do
      interval = D4::Interval.new(100_u32, 200_u32, 42_i32)
      interval.left.should eq(100_u32)
      interval.right.should eq(200_u32)
      interval.value.should eq(42_i32)
      interval.length.should eq(100_u32)
    end

    it "converts to string correctly" do
      interval = D4::Interval.new(100_u32, 200_u32, 42_i32)
      interval.to_s.should eq("100-200:42")
    end
  end

  describe "DictType" do
    it "converts to and from lib dict type" do
      simple_range = D4::DictType::SimpleRange
      lib_type = simple_range.to_lib_dict_type
      lib_type.should eq(LibD4::DictType::SimpleRange)

      converted_back = D4::DictType.from_lib_dict_type(lib_type)
      converted_back.should eq(simple_range)
    end
  end

  describe "Metadata" do
    it "creates metadata with chromosomes" do
      chromosomes = {"chr1" => 1000_u32, "chr2" => 2000_u32}
      metadata = D4::Metadata.new(chromosomes, D4::DictType::SimpleRange, 1.0)

      metadata.chromosomes.should eq(chromosomes)
      metadata.dict_type.should eq(D4::DictType::SimpleRange)
      metadata.denominator.should eq(1.0)
      metadata.chromosome_count.should eq(2)
      metadata.has_chromosome?("chr1").should be_true
      metadata.has_chromosome?("chr3").should be_false
      metadata.chromosome_size("chr1").should eq(1000_u32)
      metadata.chromosome_size("chr3").should be_nil
    end
  end

  describe "File.create_intervals" do
    it "creates intervals from positions and values" do
      positions = [100_u32, 200_u32, 300_u32]
      values = [1_i32, 2_i32, 3_i32]

      intervals = D4::File.create_intervals(positions, values)
      intervals.size.should eq(3)

      intervals[0].left.should eq(100_u32)
      intervals[0].right.should eq(200_u32)
      intervals[0].value.should eq(1_i32)

      intervals[1].left.should eq(200_u32)
      intervals[1].right.should eq(300_u32)
      intervals[1].value.should eq(2_i32)

      intervals[2].left.should eq(300_u32)
      intervals[2].right.should eq(301_u32) # Last interval gets +1
      intervals[2].value.should eq(3_i32)
    end

    it "raises error for mismatched array sizes" do
      positions = [100_u32, 200_u32]
      values = [1_i32, 2_i32, 3_i32]

      expect_raises(ArgumentError, "Positions and values arrays must have the same size") do
        D4::File.create_intervals(positions, values)
      end
    end
  end

  describe "File.create_dense_intervals" do
    it "creates dense intervals from values" do
      values = [1_i32, 2_i32, 3_i32]
      intervals = D4::File.create_dense_intervals(100_u32, values)

      intervals.size.should eq(3)

      intervals[0].left.should eq(100_u32)
      intervals[0].right.should eq(101_u32)
      intervals[0].value.should eq(1_i32)

      intervals[1].left.should eq(101_u32)
      intervals[1].right.should eq(102_u32)
      intervals[1].value.should eq(2_i32)

      intervals[2].left.should eq(102_u32)
      intervals[2].right.should eq(103_u32)
      intervals[2].value.should eq(3_i32)
    end
  end

  describe "error handling" do
    it "clears errors" do
      D4.clear_errors
      # Should not raise any exception
    end

    it "gets error number" do
      error_num = D4.error_number
      error_num.should be_a(Int32)
    end
  end

  # Note: File I/O tests would require actual D4 files and the d4binding library
  # These tests focus on the Crystal-specific functionality that doesn't require
  # external dependencies
end
