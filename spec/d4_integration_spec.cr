require "./spec_helper"

# Integration tests requiring the native d4binding library.
# If the native library (d4binding) が利用できない場合はテストを事実上スキップ（早期 return）。

describe "D4 integration" do
  it "creates, writes, reads back basic data" do
    path = File.join(Dir.tempdir, "crystal_d4_integration_test.d4")
    File.delete(path) if File.exists?(path)

    begin
      D4::File.open(path, "w") { |f| }
    rescue D4::D4Error
      # d4binding が利用できない環境: 何も検証せず終了
      next
    end

    D4.writer(path) do |w|
      w.set_chromosomes({"chr1" => 30_u32, "chr2" => 25_u32})
      w.write_values("chr1", 0_u32, [1, 2, 3])
      w.write_dense_values("chr2", 5_u32, [9, 9, 10, 10])
      intervals = [
        D4::Interval.new(5_u32, 10_u32, 7),
        D4::Interval.new(10_u32, 12_u32, 8),
      ]
      w.write_intervals("chr1", intervals)
    end

    D4.open(path) do |f|
      f.chromosomes["chr1"].should eq(30_u32)
      f.values("chr1", 0_u32, 3_u32).should eq([1, 2, 3])
      f.values("chr2", 5_u32, 9_u32).should eq([9, 9, 10, 10])
    end

    begin
      D4.build_index(path)
    rescue D4::D4Error
      # index 未対応環境でも失敗させない
    end
  end
end
