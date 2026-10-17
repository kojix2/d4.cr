# d4.cr

A pure Crystal reader and writer for [D4](https://github.com/38/d4-format) genomic data files. No Rust runtime or `d4binding` library is required.

## Install

Add this shard to `shard.yml`, then run `shards install`:

```yaml
dependencies:
  d4:
    github: kojix2/d4.cr
```

Requires Crystal 1.21 or later.

## Usage

```crystal
require "d4"

D4.create("depth.d4", chromosomes: [D4::Chromosome.new("chr1", 1000_i64)],
  dictionary: D4::Dictionary.new(0_i32, 8_i32)) do |writer|
  writer.write_values("chr1", 0, [1_i32, 2_i32, 3_i32])
end

D4.open("depth.d4") do |file|
  p file.values("chr1", 0, 3) # => [1, 2, 3]
  p file.sum("chr1", 0, 3)    # => 6
end
```

The reader supports multiple tracks, embedded indexes, and raw or DEFLATE secondary data. The writer creates one track. HTTP range reading is available with `require "d4/http"`.

Long writes and index construction support progress reporting and cooperative
cancellation. Output is published only after finalization succeeds:

```crystal
control = D4::WriteControl.new { |progress| puts progress }

D4.create("depth.d4", chromosomes: chromosomes, control: control) do |writer|
  writer.write_values("chr1", 0, values)
end

# Another fiber or thread may call control.cancel.
```

The same control can be passed to `D4.build_indexes` or directly to
`D4::Writer` and `D4::IndexBuilder`.

A GUI coverage viewer is available in the [d4-plot repository](https://github.com/kojix2/d4-plot).

## Large files

D4 files can be several gigabytes even when chromosome lengths fit in
`Int32`. Use `scan_values` or `each_value` to read large regions;
`values` has a materialization limit. The `Enumerable` overload of
`Writer#write_values` writes in 65,536-value chunks, so streaming input
does not require a chromosome-sized array. All bulk write methods return
an `Int64` count.
Chromosome lengths and returned genomic positions use `Int64`. Pass an
ordered array of `D4::Chromosome` objects to `D4.create`; the writer is
fully configured at creation. Chromosome lengths are checked against the
supported `UInt32` coordinate range.

## Development

```sh
crystal spec --single-module
crystal tool format --check src spec
```

## License

MIT. See [LICENSE](LICENSE). Rust-generated test fixtures retain the upstream notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
