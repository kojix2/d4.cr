# D4.cr

[![test](https://github.com/kojix2/d4.cr/actions/workflows/test.yml/badge.svg)](https://github.com/kojix2/d4.cr/actions/workflows/test.yml)
[![Lines of Code](https://img.shields.io/endpoint?url=https%3A%2F%2Ftokei.kojix2.net%2Fbadge%2Fgithub%2Fkojix2%2Fd4.cr%2Flines)](https://tokei.kojix2.net/github/kojix2/d4.cr)
![Static Badge](https://img.shields.io/badge/PURE-VIBE_CODING-magenta)

Crystal bindings for the D4 format - a fast and compact format for storing quantitative genomic data.

## Installation

### Prerequisites

Install the `d4binding` library on your system.

### Add to your project

```yaml
dependencies:
  d4:
    github: kojix2/d4
```

Run `shards install`

## Usage

```crystal
require "d4"
```

### Reading D4 files

```crystal
D4.open("data.d4") do |d4|
  puts d4.chromosomes

  values = d4.values("chr1", 1000_u32, 2000_u32)
  puts "Mean depth: #{values.sum / values.size}"

  d4.query("chr1", 1000_u32, 2000_u32) do |interval|
    puts "#{interval.left}-#{interval.right}: #{interval.value}"
  end

  intervals = d4.query("chr1", 1000_u32, 2000_u32)
  puts "Found #{intervals.size} intervals"

  d4.query_iter("chr1", 1000_u32, 2000_u32).each do |interval|
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
    D4::Interval.new(100_u32, 200_u32, 10_i32),
    D4::Interval.new(200_u32, 300_u32, 20_i32)
  ]
  writer.write_intervals("chr1", intervals)

  writer.write_dense_values("chr2", 0_u32, [5_i32, 6_i32, 7_i32])
end
```

### Working with intervals

```crystal
interval = D4::Interval.new(100_u32, 200_u32, 42_i32)
puts interval.length  # => 100
puts interval         # => "100-200:42"

positions = [100_u32, 200_u32, 300_u32]
values = [1_i32, 2_i32, 3_i32]
intervals = D4::File.create_intervals(positions, values)

dense_intervals = D4::File.create_dense_intervals(100_u32, [1_i32, 2_i32, 3_i32])
```

### Building indices

```crystal
D4.build_index("data.d4")
```

### Error handling

```crystal
begin
  D4.open("nonexistent.d4") do |d4|
    # This will raise D4::D4Error
  end
rescue D4::D4Error => e
  puts "D4 error: #{e.message}"
end

D4.clear_errors
```

## API

### Classes

- `D4::File` - Main class for reading and writing D4 files
- `D4::Writer` - Convenience class for creating D4 files
- `D4::Interval` - Represents a genomic interval with a value
- `D4::Metadata` - Contains chromosome and dictionary information
- `D4::QueryIterator` - Memory-efficient iterator for querying intervals

### Enums

- `D4::DictType` - Dictionary types (SimpleRange, ValueMap)

### Exceptions

- `D4::D4Error` - D4-specific errors with detailed messages

## Design

This implementation follows the same design principles as d4-nim:

- Core functionality only (no BAM/CRAM processing)
- Simple dependencies (only requires `d4binding` library, no htslib)
- Memory efficient with proper cleanup of C resources
- Type safe using Crystal's type system

## Development

1. Install the `d4binding` library
2. Clone this repository
3. Run `shards install`
4. Run tests with `crystal spec`

## License

MIT License

## Contributors

- [kojix2](https://github.com/kojix2) - creator and maintainer

## Acknowledgments

- [Hao Hou](https://github.com/38) - creator of the D4 format
- [Brent Pedersen](https://github.com/brentp) - creator of d4-nim
