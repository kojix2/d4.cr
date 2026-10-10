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

A GUI coverage viewer is available in [examples/d4-plot](examples/d4-plot).

## Development

```sh
crystal spec --single-module
crystal tool format --check src spec
```

## License

MIT. See [LICENSE](LICENSE). Rust-generated test fixtures retain the upstream notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
