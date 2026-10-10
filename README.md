# d4.cr

[![test](https://github.com/kojix2/d4.cr/actions/workflows/test.yml/badge.svg)](https://github.com/kojix2/d4.cr/actions/workflows/test.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Fd4.cr%2Flines)](https://tokei.kojix2.net/github/kojix2/d4.cr)
![Static Badge](https://img.shields.io/badge/implementation-pure%20Crystal-6f42c1)

Pure Crystal reader and writer for the [D4 format](https://github.com/38/d4-format) - a compact format for genomic quantitative data.

## Installation

### Add to your project

```yaml
dependencies:
  d4:
    github: kojix2/d4.cr
```

Run `shards install`

## Usage

```crystal
require "d4"
```

### Reading D4 files

```crystal
D4.open("data.d4") do |d4|
  puts d4.chromosomes.map(&.name)

  values = d4.values("chr1", 1000_u32, 2000_u32)
  puts "Mean depth: #{values.sum / values.size}"

  d4.each_interval("chr1", 1000, 2000) do |interval|
    puts "#{interval.left}-#{interval.right}: #{interval.value}"
  end

  intervals = d4.query("chr1", 1000, 2000)
  puts "Found #{intervals.size} intervals"

  d4.each_interval("chr1", 1000, 2000).each do |interval|
    puts interval
  end
end
```

### Writing D4 files

```crystal
D4.writer("output.d4") do |writer|
  chromosomes = {"chr1" => 1000_u32, "chr2" => 2000_u32}
  writer.set_chromosomes(chromosomes)

  values = [1_i32, 2_i32, 3_i32, 4_i32, 5_i32]
  writer.write_values("chr1", 0_u32, values)

  intervals = [
    D4::RawInterval.new(100, 200, 10_i32),
    D4::RawInterval.new(200, 300, 20_i32)
  ]
  writer.write_intervals("chr1", intervals)

  writer.write_dense_values("chr2", 0_u32, [5_i32, 6_i32, 7_i32])
end
```

### Statistics and multiple tracks

```crystal
D4.open("depth.d4") do |file|
  region = D4::Region.new("chr1", 100, 200)
  puts file.summary("chr1", 100, 200).mean
  histogram = file.histogram(region, value_range: -10_i32...100_i32)
  puts histogram.counts
  puts file.coverage(region, thresholds: [1_i32, 10_i32]).counts
  puts file.scaled.mean("chr1", 100, 200) # stored mean / denominator
end

D4.open("multitrack.d4") do |file|
  matrix = file.matrix(["normal", "tumor"])
  rows = Slice(Int32).new(4096 * matrix.column_count)
  matrix.scan_rows(D4::Region.new("chr1", 0, 100_000), rows) do |start, values, count|
    # values are borrowed, row-major, and overwritten on the next block
  end
end
```

The reader supports raw and DEFLATE secondary tables, single/multi-track containers, and simple-range/value-map dictionaries. The writer creates one track, with optional `WriteOptions.new(compression: D4::Compression.deflate(level: 5))`. It spools runs to temporary storage and publishes a completed file only after success. Existing files are preserved unless `WriteOptions.new(overwrite: true)` is explicit. Use `D4.create` to supply a dictionary, denominator, and default value.

Region and matrix aggregations accept `workers: 2` (or another positive count).
This uses a reused Crystal parallel execution context and returns results in
input order. Bounded batches are available with `each_aggregate(...,
workers: 2, batch_size: 256)`. Worker counts above the available CPU count
are capped internally. A shared local source serializes reads, so parallel
speedups depend on input shape and storage. `bench/speed.cr` measures both
continuous scans and multi-region aggregation in a release build.

`examples/d4-plot` is a GUI viewer that uses the pure-Crystal sampler, and
uses a sum index for wide plot bins when available. Its UIng/GTK dependencies
are separate from the core shard.

### Embedded indexes

Indexes live **inside** the D4 file, under `.index`, not in a `.bai`-style
sidecar. Build both indexes on an existing local D4 (copied to a temporary
file in the same directory and replaced only on success):

```crystal
D4.build_indexes("depth.d4")
D4.build_indexes("multi.d4", track: "sample_a")

D4.open("depth.d4") do |file|
  p file.default_track.has_index?(D4::IndexKind::SecondaryFrames)
  p file.sum("chr1", 0, 1_000_000, index: D4::IndexPolicy::Require)
end
```

New files can request indexes with
`D4::WriteOptions.new(indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum])`.
The secondary-frame index accelerates random reads of secondary records;
the sum index accelerates exact whole-block sums while scanning unaligned
endpoints. `Auto` falls back to scanning if no usable sum index is present,
`Scan` skips the sum index, and `Require` raises when it is missing or cannot
guarantee exactness. Existing indexes are validated before use. SFI entries
are binary-searched on disk instead of materializing per-entry objects.

### HTTP byte ranges

HTTP is optional and uses Crystal's standard HTTP client:

```crystal
require "d4/http"

source = D4::HTTPSource.new("https://example.org/depth.d4")
D4.open(source, sync_close: true) do |file|
  puts file.sum("chr1", 0, 1_000_000)
end
```

The server must support byte Range requests (`206` and valid `Content-Range`).
A `200` response is rejected rather than downloading the full file. The
bounded LRU cache defaults to 64 blocks of 64 KiB (4 MiB). Do not mutate a
remote D4 while a reader is open; a changed ETag or file length is rejected.
URLs are separate from local path opening: `D4.open("https://…")` is not used.

Benchmark `bench/index.cr` compares warmed, repeated point reads before and
after indexing; `bench/speed.cr` covers primary-table scans and region
aggregation. `bench/compare.cr` and `bench/compare.c` can compare reads and
writes with the Rust D4 C API; `bench/run_comparison.py` and
`bench/run_write_comparison.py` record wall time and peak RSS.
`bench/run_1g_comparison.py` repeats scans on pre-generated approximately
1 GB or 2 GB files and checks their sums; the companion reports distinguish
file-backed RSS from anonymous memory. The Rust executable has read
Crystal-generated primary-only and secondary-heavy files,
including Crystal-built SFI and SUM indexes. A Rust-built indexed fixture is
also checked by the Crystal specs. Rust 0.3.11 writes an incomplete final SUM
bin in some files; Crystal scans that bin instead of reading past its blob.
Unindexed reads of large secondary tables can still be slow.

See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for remaining PLAN milestones.

### Error handling

```crystal
begin
  D4.open("data.d4") do |d4|
    puts d4.value("chr1", 100)
  end
rescue D4::Error => e
  puts "Invalid D4 data or query: #{e.message}"
end

```

## API

### Classes

- `D4::File`, `D4::Track`, `D4::Matrix`, `D4::ScaledTrack` - Reading views
- `D4::Writer` - Single-track D4 output
- `D4::Interval(T)` / `D4::RawInterval` - Represents an owned genomic interval
- `D4::Metadata` - Contains chromosome and dictionary information
- `D4::Source`, `D4::MemorySource`, `D4::LocalSource`, `D4::IOSource` - random-access byte sources

### Enums

- `D4::DictType` - Legacy writer dictionary selector

### Exceptions

- `D4::Error`, `D4::FormatError`, `D4::UnsupportedFeatureError`

## Design

This implementation follows the D4 format directly:

- Core functionality only (no BAM/CRAM processing)
- No d4binding, Rust runtime, or htslib dependency
- Offset-based Source API and bounded materialization
- Public domain objects are classes; low-allocation paths use caller-owned buffers

## Development

1. Install Crystal 1.21 or later
2. Clone this repository
3. Run `shards install`
4. Run `crystal spec --single-module`
5. Run `crystal tool format --check src spec` and `shards run ameba -- src spec`

## License

MIT License

The C benchmark header and upstream test data are covered by the notices in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Acknowledgments

- [Hao Hou](https://github.com/38) - creator of the D4 format
- [Brent Pedersen](https://github.com/brentp) - creator of d4-nim
