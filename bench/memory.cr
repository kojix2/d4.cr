require "../src/d4"

# Run with `crystal build --release bench/memory.cr -o /tmp/d4-memory-bench`
# and `/tmp/d4-memory-bench 1000000` (or `2000000`).
count = (ARGV[0]? || "1000000").to_i
raise ArgumentError.new("count must be positive") if count <= 0
path = File.join(Dir.tempdir, "d4-memory-#{Process.pid}.d4")
begin
  before = GC.stats
  D4.create(path, chromosomes: [D4::Chromosome.new("chr", count.to_i64)],
    dictionary: D4::Dictionary.new([0_i32])) do |writer|
    count.times { |position| writer.write_value("chr", position, position.even? ? 1_i32 : 2_i32) }
  end
  after_write = GC.stats
  total = 0_i64
  D4.open(path) do |file|
    file.each_value("chr") { |value| total += value }
  end
  after_read = GC.stats
  puts "bases=#{count} checksum=#{total}"
  puts "heap_before=#{before.heap_size} heap_after_write=#{after_write.heap_size} heap_after_read=#{after_read.heap_size}"
  puts "allocated_write=#{after_write.total_bytes - before.total_bytes} allocated_read=#{after_read.total_bytes - after_write.total_bytes}"
ensure
  File.delete(path) if File.exists?(path)
end
