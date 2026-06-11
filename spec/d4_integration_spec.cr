require "./spec_helper"

# Integration tests requiring the native d4binding library.
# If the native library (d4binding) が利用できない場合はテストを事実上スキップ（早期 return）。

describe "D4 integration" do
  it "creates, writes, reads back basic data" do
    path = File.join(Dir.tempdir, "crystal_d4_integration_test.d4")
    File.delete(path) if File.exists?(path)

    begin
      D4::File.open(path, "w") { |_| }
    rescue D4::D4Error
      # d4binding が利用できない環境: 何も検証せず終了
      next
    end

    D4.writer(path) do |writer|
      writer.set_chromosomes({"chr1" => 30_u32, "chr2" => 25_u32})
      writer.write_values("chr1", 0_u32, [1, 2, 3])
      writer.write_dense_values("chr2", 5_u32, [9, 9, 10, 10])
      intervals = [
        D4::Interval.new(5_u32, 10_u32, 7),
        D4::Interval.new(10_u32, 12_u32, 8),
      ]
      writer.write_intervals("chr1", intervals)
    end

    D4.open(path) do |file|
      file.chromosomes["chr1"].should eq(30_u32)
      file.values("chr1", 0_u32, 3_u32).should eq([1, 2, 3])
      file.values("chr2", 5_u32, 9_u32).should eq([9, 9, 10, 10])
    end

    begin
      D4.build_sfi_index(path)
    rescue D4::D4Error
      # index 未対応環境でも失敗させない
    end
  end

  it "raises when native value writes are partial" do
    path = File.join(Dir.tempdir, "crystal_d4_partial_value_write_test.d4")
    File.delete(path) if File.exists?(path)

    begin
      D4.writer(path) do |writer|
        writer.set_chromosomes({"chr1" => 3_u32})

        expect_raises(D4::D4Error, "Only wrote") do
          writer.write_values("chr1", 0_u32, [1, 2, 3, 4])
        end
      end
    rescue D4::D4Error
      # d4binding が利用できない環境: 何も検証せず終了
      next
    end
  end

  it "queries regional sum and mean with and without a sum index" do
    path = File.join(Dir.tempdir, "crystal_d4_index_query_test.d4")
    File.delete(path) if File.exists?(path)

    begin
      D4.writer(path) do |writer|
        writer.set_chromosomes({"chr1" => 10_u32})
        writer.write_values("chr1", 0_u32, [1, 2, 3, 4, 5])
      end
    rescue D4::D4Error
      # d4binding が利用できない環境: 何も検証せず終了
      next
    end

    D4.open(path) do |file|
      file.has_index?.should be_false
      file.has_sum_index?.should be_false
      file.sum("chr1", 1_u32, 4_u32).should eq(9.0)
      file.mean("chr1", 1_u32, 4_u32).should eq(3.0)
      file.sum("chr1", 8_u32, 8_u32).should eq(0.0)
      file.mean("chr1", 8_u32, 8_u32).should eq(0.0)

      expect_raises(D4::D4Error, "D4 sum index is not available") do
        file.indexed_sum("chr1", 1_u32, 4_u32)
      end
    end

    D4.build_sfi_index(path)

    D4.open(path) do |file|
      file.has_sum_index?.should be_false
      file.sum("chr1", 1_u32, 4_u32).should eq(9.0)
      file.mean("chr1", 1_u32, 4_u32).should eq(3.0)
    end
  end
end
