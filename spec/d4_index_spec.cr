require "spec"
require "../src/d4"

class CountingD4Source < D4::Source
  getter bytes_read : Int64 = 0_i64

  def initialize(path : String)
    @source = D4::LocalSource.new(path)
  end

  def size : Int64
    @source.size
  end

  def read_at(offset : Int64, buffer : Bytes) : Int32
    count = @source.read_at(offset, buffer)
    @bytes_read += count
    count
  end

  def reset : Nil
    @bytes_read = 0_i64
  end

  def close : Nil
    @source.close
  end

  def closed? : Bool
    @source.closed?
  end
end

describe "embedded D4 indexes" do
  it "reads Rust-built packed indexes and falls back for an incomplete final SUM bin" do
    path = File.join(__DIR__, "fixtures", "rust-indexed-sparse-100k.d4")
    D4.open(path) do |file|
      track = file.default_track
      track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
      track.has_index?(D4::IndexKind::Sum).should be_true
      file.value("chr", 99_900).should eq(100)
      file.sum("chr", index: D4::IndexPolicy::Require).should eq(448_000_i64)
      file.sum("chr", 65_500, 70_000, index: D4::IndexPolicy::Require).should eq(
        file.sum("chr", 65_500, 70_000, index: D4::IndexPolicy::Scan))
    end
  end

  it "builds both indexes while writing and reads late secondary records" do
    temporary = File.tempfile("d4-index-spec", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      options = D4::WriteOptions.new(indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum])
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 131_072_i64)],
        dictionary: D4::Dictionary.new([0_i32]), options: options) do |writer|
        20_000.times { |position| writer.write_value("chr", position, position.even? ? 1_i32 : 2_i32) }
      end
      D4.open(path) do |file|
        root = D4::Format::Directory.open_root(file.source, file.options.max_metadata_bytes)
        indexed = root.entry(".index", 1_u8)
        parts = D4::Format::Directory.open(file.source, indexed.offset, file.options.max_metadata_bytes)
        parts.entries.each do |entry|
          (entry.offset + entry.size).should be <= (indexed.offset + indexed.size)
        end
        file.default_track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
        file.default_track.has_index?(D4::IndexKind::Sum).should be_true
        file.value("chr", 19_999).should eq(2_i32)
        file.sum("chr", 14_000, 20_000, index: D4::IndexPolicy::Require).should eq(9_000_i64)
        file.sum("chr", 0, 131_072, index: D4::IndexPolicy::Require).should eq(30_000_i64)
      end
      counting = CountingD4Source.new(path)
      D4.open(counting, sync_close: true) do |file|
        counting.reset
        file.value("chr", 19_999).should eq(2_i32)
        counting.bytes_read.should be < 100_000_i64
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "adds indexes safely to an existing D4 and preserves its values" do
    original = File.join(__DIR__, "fixtures", "rust-input-10nt.d4")
    temporary = File.tempfile("d4-index-existing", ".d4")
    path = temporary.path
    begin
      File.open(original, "rb") { |input| IO.copy(input, temporary) }
      temporary.close
      before = File.read(path)
      expect_raises(D4::TrackSelectionError) { D4.build_indexes(path, track: "missing") }
      File.read(path).should eq(before)
      D4.build_indexes(path)
      D4.open(path) do |file|
        file.default_track.has_index?(D4::IndexKind::Sum).should be_true
        file.sum("chr", index: D4::IndexPolicy::Require).should eq(file.sum("chr", index: D4::IndexPolicy::Scan))
      end
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "indexes DEFLATE secondary frames" do
    temporary = File.tempfile("d4-index-deflate", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      options = D4::WriteOptions.new(compression: D4::Compression.deflate,
        indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum])
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 20_000_i64)],
        dictionary: D4::Dictionary.new([0_i32]), options: options) do |writer|
        20_000.times { |position| writer.write_value("chr", position, position.even? ? 1_i32 : 2_i32) }
      end
      D4.open(path) do |file|
        file.value("chr", 19_999).should eq(2_i32)
        file.sum("chr", index: D4::IndexPolicy::Require).should eq(30_000_i64)
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "builds indexes in a selected track of a multi-track Rust file" do
    original = File.join(__DIR__, "fixtures", "rust-multitrack.d4")
    temporary = File.tempfile("d4-index-multi", ".d4")
    path = temporary.path
    begin
      File.open(original, "rb") { |input| IO.copy(input, temporary) }
      temporary.close
      D4.build_indexes(path, track: "input2")
      D4.open(path, track: "input2") do |file|
        file.default_track.has_index?(D4::IndexKind::SecondaryFrames).should be_true
        file.default_track.has_index?(D4::IndexKind::Sum).should be_true
        file.sum("1", 0, 2, index: D4::IndexPolicy::Require).should eq(0_i64)
      end
      D4.open(path, track: "input") { |file| file.default_track.has_index?(D4::IndexKind::Sum).should be_false }
    ensure
      temporary.close unless temporary.closed?
      File.delete(path) if File.exists?(path)
    end
  end

  it "rejects a corrupted sum entry even in automatic mode" do
    temporary = File.tempfile("d4-index-corrupt", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 131_072_i64)],
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::Sum])) { |writer| }
      source = D4::LocalSource.new(path)
      begin
        root = D4::Format::Directory.open_root(source, 4_194_304_i64)
        index = D4::Format::Directory.open(source, root.entry(".index", 1_u8).offset, 4_194_304_i64)
        blob = index.entry("sum_index", 2_u8)
        File.open(path, "r+b") do |output|
          output.seek(blob.offset + 8, IO::Seek::Set)
          output.write(Bytes.new(8, 0xff_u8))
        end
      ensure
        source.close
      end
      D4.open(path) do |file|
        expect_raises(D4::CorruptIndexError) { file.sum("chr", index: D4::IndexPolicy::Auto) }
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
