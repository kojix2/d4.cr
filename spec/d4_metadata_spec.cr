require "./spec_helper"

describe "D4 metadata validation" do
  it "normalizes malformed header schemas while preserving malformed-JSON errors" do
    expect_raises(D4::FormatError, /invalid D4 metadata: Missing hash key/) do
      D4::HeaderParser.parse(%({}).to_slice)
    end
    expect_raises(D4::FormatError, /invalid D4 metadata: Cast from String/) do
      D4::HeaderParser.parse(%({"chrom_list":"chr","dictionary":{}}).to_slice)
    end
    expect_raises(D4::FormatError, /invalid D4 metadata JSON/) do
      D4::HeaderParser.parse(%({).to_slice)
    end
  end

  it "validates header coordinate and dictionary integer bounds" do
    valid = %({"chrom_list":[{"name":"chr","size":4294967295}],"dictionary":{"SimpleRange":{"low":-2147483648,"high":0}}})
    metadata = D4::HeaderParser.parse(valid.to_slice)
    metadata.chromosome_size("chr").should eq(UInt32::MAX.to_i64)
    metadata.dictionary.low.should eq(Int32::MIN)

    oversized_chromosome = %({"chrom_list":[{"name":"chr","size":4294967296}],"dictionary":{"SimpleRange":{"low":0,"high":2}}})
    expect_raises(D4::FormatError, /chromosome size/) do
      D4::HeaderParser.parse(oversized_chromosome.to_slice)
    end
    oversized_dictionary_value = %({"chrom_list":[],"dictionary":{"SimpleRange":{"low":0,"high":2147483648}}})
    expect_raises(D4::FormatError, /dictionary value/) do
      D4::HeaderParser.parse(oversized_dictionary_value.to_slice)
    end
  end

  it "shares required-key, type, and coordinate validation for secondary metadata" do
    valid = %({"record_format":"range","compression":{"Deflate":4294967295},"partitions":[["chr",0,4294967295]]})
    metadata = D4::SecondaryMetadataParser.parse(valid.to_slice)
    metadata.compressed.should be_true
    metadata.partitions.map { |part| {part.chromosome, part.start, part.stop} }.should eq(
      [{"chr", 0_i64, UInt32::MAX.to_i64}])

    expect_raises(D4::FormatError, /invalid secondary metadata: Missing hash key/) do
      D4::SecondaryMetadataParser.parse(%({}).to_slice)
    end
    expect_raises(D4::FormatError, /invalid secondary metadata: Cast from String/) do
      D4::SecondaryMetadataParser.parse(%({"record_format":"range","partitions":"bad"}).to_slice)
    end
    expect_raises(D4::FormatError, /invalid secondary partition/) do
      D4::SecondaryMetadataParser.parse(%({"record_format":"range","partitions":[["chr",0,4294967296]]}).to_slice)
    end
    expect_raises(D4::FormatError, /compression level/) do
      D4::SecondaryMetadataParser.parse(%({"record_format":"range","compression":{"Deflate":-1},"partitions":[]}).to_slice)
    end
    expect_raises(D4::UnsupportedFeatureError, /record format/) do
      D4::SecondaryMetadataParser.parse(%({"record_format":"other","partitions":[]}).to_slice)
    end
  end

  it "applies secondary schema validation while opening a table" do
    frame = D4::Format.bytes(D4::FrameEncoder.build_exact(%({}).to_slice))
    source = D4::MemorySource.new(frame)
    directory = D4::Format::Directory.new(0_i64, [
      D4::Format::Entry.new(0_u8, 0_i64, frame.size.to_i64, ".metadata"),
    ])

    expect_raises(D4::FormatError, /invalid secondary metadata: Missing hash key/) do
      D4::SecondaryTable.new(source, directory, D4::ReadOptions.new, nil)
    end
  end
end
