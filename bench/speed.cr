require "../src/d4"

# Build with `crystal build --release bench/speed.cr -o /tmp/d4-speed-bench`.
# Run with `/tmp/d4-speed-bench 8000000`; Linux peak RSS is printed below.
# Single process, warmed file cache, medians of five runs; no Rust comparison.
size = (ARGV[0]? || "8000000").to_i
raise ArgumentError.new("size must be a positive multiple of 64") if size <= 0 || size % 64 != 0
path = File.join(Dir.tempdir, "d4-speed-#{Process.pid}.d4")
buffer = Slice(Int32).new(65_536) { |index| (index % 4).to_i32 }
regions = Array(D4::Region).new(64) do |index|
  D4::Region.new("chr", index.to_i64 * size // 64, (index.to_i64 + 1) * size // 64)
end

begin
  D4.create(path, chromosomes: [D4::Chromosome.new("chr", size.to_i64)],
    dictionary: D4::Dictionary.new(0_i32, 8_i32)) do |writer|
    offset = 0
    while offset < size
      count = Math.min(buffer.size, size - offset)
      writer.write_values("chr", offset, buffer[0, count])
      offset += count
    end
  end

  D4.open(path) do |file|
    reducer = D4::Reducers::Sum.new
    scratch = Slice(Int32).new(65_536)
    checksum = 0_i64
    scan = -> {
      total = 0_i64
      file.default_track.scan_values(D4::Region.new("chr", 0, size.to_i64), scratch) do |_, values, count|
        count.times { |index| total += values[index] }
      end
      total
    }
    measure = ->(label : String, work : -> Int64) {
      work.call # warm-up
      durations = Array(Float64).new(5)
      allocated = 0_i64
      5.times do
        before_alloc = GC.stats.total_bytes
        before = Time.instant
        checksum = work.call
        durations << (Time.instant - before).total_milliseconds
        allocated += GC.stats.total_bytes - before_alloc
      end
      durations.sort!
      puts "#{label}: median_ms=#{durations[2].round(2)} Mbases_per_s=#{(size / durations[2] / 1000).round(2)} allocated_bytes_avg=#{allocated // 5} checksum=#{checksum}"
    }
    measure.call("scan", scan)
    {1, 2, 4}.each do |workers|
      measure.call("aggregate_#{workers}", -> { file.aggregate(regions, reducer, workers: workers).sum(0_i64, &.value) })
    end
  end
  if File.exists?("/proc/self/status")
    if peak = File.read("/proc/self/status").lines.find(&.starts_with?("VmHWM:"))
      puts peak.strip
    end
  end
ensure
  File.delete(path) if File.exists?(path)
end
