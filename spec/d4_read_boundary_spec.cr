require "./spec_helper"

describe "D4 read coordinate boundaries" do
  it "normalizes unsigned and wide public coordinates to ArgumentError" do
    expect_raises(ArgumentError, /region coordinate/) do
      D4::Region.new("chr", UInt64::MAX...UInt64::MAX)
    end
    expect_raises(ArgumentError, /region coordinate/) do
      D4::Region.new("chr", Int128::MAX...Int128::MAX)
    end

    temporary = File.tempfile("d4-read-boundary", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path,
        chromosomes: [D4::Chromosome.new("chr", 4_i64)],
        dictionary: D4::Dictionary.new(0_i32, 2_i32)) do |writer|
        writer.write_values("chr", 0, [1_i32, 1_i32, 0_i32, 0_i32])
      end

      D4.open(path) do |file|
        track = file.default_track
        scaled = file.scaled
        matrix = file.matrix([""])
        buffer = Slice(Int32).new(1)
        scaled_buffer = Slice(Float64).new(1)

        expect_raises(ArgumentError, /invalid point coordinate/) { track.value("chr", UInt64::MAX) }
        expect_raises(ArgumentError, /invalid point coordinate/) { file.value("chr", Int128::MAX) }
        expect_raises(ArgumentError, /invalid region/) { track.values("chr", UInt64::MAX) }
        expect_raises(ArgumentError, /invalid region/) { file.values("chr", 0, UInt64::MAX) }
        expect_raises(ArgumentError, /invalid region/) { track.read_values_into("chr", UInt64::MAX, buffer) }
        expect_raises(ArgumentError, /invalid region/) do
          track.scan_values("chr", buffer, UInt64::MAX) { |_position, _values, _count| }
        end
        expect_raises(ArgumentError, /invalid region/) do
          track.each_value("chr", UInt64::MAX) { |_value| }
        end
        expect_raises(ArgumentError, /invalid region/) { track.each_value("chr", UInt64::MAX) }
        expect_raises(ArgumentError, /invalid region/) do
          track.each_interval("chr", UInt64::MAX) { |_interval| }
        end
        expect_raises(ArgumentError, /invalid region/) { track.each_interval("chr", UInt64::MAX) }
        expect_raises(ArgumentError, /invalid region/) { file.sum("chr", Int128::MAX) }
        expect_raises(ArgumentError, /invalid region/) { file.mean("chr", UInt64::MAX) }
        expect_raises(ArgumentError, /invalid region/) { file.summary("chr", UInt64::MAX) }
        expect_raises(ArgumentError, /invalid region/) { scaled.values("chr", UInt64::MAX) }
        expect_raises(ArgumentError, /invalid region/) do
          scaled.read_values_into("chr", UInt64::MAX, scaled_buffer)
        end
        expect_raises(ArgumentError, /invalid row start/) do
          matrix.read_rows_into("chr", UInt64::MAX, buffer)
        end
        expect_raises(ArgumentError, /invalid row start/) do
          matrix.scaled.read_rows_into("chr", UInt64::MAX, scaled_buffer)
        end
        expect_raises(ArgumentError, /bin_size must be positive/) do
          file.each_bin(D4::Region.new("chr", 0_i64, 4_i64), bin_size: UInt64::MAX)
        end

        file.values("chr", 0, 4).should eq([1_i32, 1_i32, 0_i32, 0_i32])
      end
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end
end
