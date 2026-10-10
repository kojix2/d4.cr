require "../src/d4"

# Cross-language benchmark companion to compare.c. No output is produced while
# scanning, so formatting and terminal throughput do not enter the timings.
mode = ARGV[0]
path = ARGV[1]
chrom = ARGV[0] == "scan" && ARGV[3]? ? ARGV[3] : "chr"
case mode
when "generate-dual"
  length = ARGV[2].to_i64
  dictionary = D4::Dictionary.new(0_i32, 8_i32)
  values = Slice(Int32).new(65_536)
  D4.create(path, chromosomes: [D4::Chromosome.new("chr1", length), D4::Chromosome.new("chr2", length)],
    dictionary: dictionary) do |writer|
    ["chr1", "chr2"].each do |name|
      offset = 0_i64
      while offset < length
        count = Math.min(values.size.to_i64, length - offset).to_i
        count.times { |index| values[index] = ((offset + index) % 8).to_i32 }
        writer.write_values(name, offset, values[0, count])
        offset += count
      end
    end
  end
  puts "created_bytes=#{::File.size(path)}"
when "scan-dual"
  length = ARGV[2].to_i64
  checksum = 0_i64
  before_gc = GC.stats
  D4.open(path) do |file|
    buffer = Slice(Int32).new(65_536)
    ["chr1", "chr2"].each do |name|
      file.default_track.scan_values(D4::Region.new(name, 0_i64, length), buffer) do |_, values, count|
        count.times { |index| checksum += values[index] }
      end
    end
  end
  after_gc = GC.stats
  puts "checksum=#{checksum} allocated_bytes=#{after_gc.total_bytes - before_gc.total_bytes} heap_bytes=#{after_gc.heap_size}"
when "generate-gap"
  length = ARGV[2].to_i64
  D4.create(path, chromosomes: [D4::Chromosome.new(chrom, length)],
    dictionary: D4::Dictionary.new(0_i32, 8_i32)) do |writer|
    writer.write_value(chrom, length - 1, 7_i32)
  end
  puts "created_bytes=#{::File.size(path)}"
when "generate"
  length = ARGV[2].to_i64
  pattern = ARGV[3]
  dictionary = pattern == "alternate" ? D4::Dictionary.new([0_i32]) : D4::Dictionary.new(0_i32, 8_i32)
  values = Slice(Int32).new(65_536)
  D4.create(path, chromosomes: [D4::Chromosome.new(chrom, length)], dictionary: dictionary) do |writer|
    offset = 0_i64
    while offset < length
      count = Math.min(values.size.to_i64, length - offset).to_i
      count.times do |index|
        position = offset + index
        values[index] = case pattern
                        when "primary"   then (position % 8).to_i32
                        when "sparse"    then position % 100 == 0 ? 100_i32 : (position % 8).to_i32
                        when "alternate" then position.even? ? 1_i32 : 2_i32
                        else                  raise ArgumentError.new("unknown pattern: #{pattern}")
                        end
      end
      writer.write_values(chrom, offset, values[0, count])
      offset += count
    end
  end
  puts "created_bytes=#{::File.size(path)}"
when "scan", "point", "materialize", "sum", "aggregate"
  length = ARGV[2].to_i64
  checksum = 0_i64
  before_gc = GC.stats
  options = mode == "materialize" ? D4::ReadOptions.new(max_materialized_bytes: 512_i64 * 1024 * 1024) : D4::ReadOptions.new
  D4.open(path, options: options) do |file|
    if mode == "scan"
      scratch = Slice(Int32).new(65_536)
      file.default_track.scan_values(D4::Region.new(chrom, 0_i64, length), scratch) do |_, values, count|
        count.times { |index| checksum += values[index] }
      end
    elsif mode == "materialize"
      values = file.values(chrom, 0, length)
      checksum = values.sum(0_i64)
    elsif mode == "sum"
      checksum = file.sum(chrom, 0, length)
    elsif mode == "aggregate"
      regions = Array(D4::Region).new(64) do |index|
        D4::Region.new(chrom, index.to_i64 * length // 64, (index.to_i64 + 1) * length // 64)
      end
      checksum = file.aggregate(regions, D4::Reducers::Sum.new, workers: ARGV[3].to_i).sum(0_i64, &.value)
    else
      count = ARGV[3].to_i
      count.times do |index|
        position = ((index.to_i64 * 65_537) % length).to_i
        checksum += file.value(chrom, position)
      end
    end
  end
  after_gc = GC.stats
  puts "checksum=#{checksum} allocated_bytes=#{after_gc.total_bytes - before_gc.total_bytes} heap_bytes=#{after_gc.heap_size}"
else
  raise ArgumentError.new("usage: generate|scan|point PATH LENGTH [PATTERN|POINTS]")
end
