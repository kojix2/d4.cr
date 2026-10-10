require "../src/d4"

# Build with `crystal build --release bench/index.cr -o /tmp/d4-index-bench`.
# Measures warmed repeated point reads on the same file before/after indexing.
count = (ARGV[0]? || "200000").to_i
raise ArgumentError.new("count must be at least 10000") if count < 10_000
path = File.join(Dir.tempdir, "d4-index-bench-#{Process.pid}.d4")
positions = Array(Int32).new(32) { |index| count * (3 * 32 + index) // (4 * 32) }

begin
  D4.create(path, chromosomes: [D4::Chromosome.new("chr", count.to_i64)],
    dictionary: D4::Dictionary.new([0_i32])) do |writer|
    count.times { |position| writer.write_value("chr", position, position.even? ? 1_i32 : 2_i32) }
  end

  measure = ->(name : String) {
    D4.open(path) do |file|
      checksum = 0_i64
      times = [] of Float64
      4.times do |iteration|
        start = Time.instant
        positions.each { |position| checksum += file.value("chr", position) }
        times << (Time.instant - start).total_milliseconds if iteration > 0
      end
      times.sort!
      puts "#{name}: median_ms=#{times[1].round(2)} checksum=#{checksum}"
    end
  }

  measure.call("unindexed")
  D4.build_indexes(path)
  measure.call("indexed")
ensure
  File.delete(path) if File.exists?(path)
end
