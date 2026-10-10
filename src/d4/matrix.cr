module D4
  class Row
    getter position : Int64
    getter values : Array(Int32)

    def initialize(@position : Int64, @values : Array(Int32)); end
  end

  class ScaledRow
    getter position : Int64
    getter values : Array(Float64)

    def initialize(@position : Int64, @values : Array(Float64)); end
  end

  class Matrix
    @scaled : ScaledMatrix?

    def tracks : Array(Track)
      @tracks.dup
    end

    def initialize(tracks : Enumerable(Track))
      @tracks = tracks.to_a
      raise ArgumentError.new("matrix requires at least one track") if @tracks.empty?
      raise ArgumentError.new("duplicate matrix track") unless @tracks.uniq.size == @tracks.size
      reference = @tracks.first.chromosomes
      @tracks.each do |track|
        chromosomes = track.chromosomes
        unless chromosomes.size == reference.size && chromosomes.zip(reference).all? { |a, b| a.name == b.name && a.size == b.size }
          raise ArgumentError.new("matrix tracks must have identical chromosomes and lengths")
        end
      end
    end

    def column_count : Int32
      @tracks.size
    end

    def track_names : Array(String)
      @tracks.map(&.name)
    end

    def read_rows_into(chromosome : String, start : Int, buffer : Slice(Int32)) : Int32
      @tracks.each(&.check_open)
      raise ArgumentError.new("row buffer size must be a multiple of column count") unless buffer.size % column_count == 0
      chrom_size = @tracks.first.chromosome_size(chromosome)
      raise ArgumentError.new("invalid row start") if start < 0 || start.to_i64 > chrom_size
      rows = Math.min(buffer.size // column_count, chrom_size - start.to_i64).to_i
      region = Region.new(chromosome, start.to_i64, start.to_i64 + rows)
      scanners = @tracks.map { |track| ValueScanner.new(track, region, track.secondary_table, Math.max(1, rows)) }
      fill_rows(scanners, buffer, Slice(Int32).new(rows), rows)
      rows
    end

    def scan_rows(region : Region, buffer : Slice(Int32), & : Int64, Slice(Int32), Int32 -> Nil) : Nil
      @tracks.each(&.check_open)
      raise ArgumentError.new("row buffer size must be a positive multiple of column count") if buffer.empty? || buffer.size % column_count != 0
      raise ArgumentError.new("invalid region") if region.stop > @tracks.first.chromosome_size(region.chromosome)
      scanners = @tracks.map { |track| ValueScanner.new(track, region, track.secondary_table, buffer.size // column_count) }
      scratch = Slice(Int32).new(buffer.size // column_count)
      position = region.start
      while position < region.stop
        rows = Math.min(buffer.size // column_count, region.stop - position).to_i
        fill_rows(scanners, buffer, scratch, rows)
        yield position, buffer[0, rows * column_count], rows
        position += rows
      end
    end

    def each_row(region : Region, & : Row -> Nil) : Nil
      buffer = Slice(Int32).new(Math.min(4096, 65_536 // column_count) * column_count)
      scan_rows(region, buffer) do |position, data, rows|
        rows.times do |row|
          values = Array(Int32).new(column_count) { |column| data[row * column_count + column] }
          yield Row.new(position + row, values)
        end
      end
    end

    def scaled : ScaledMatrix
      @scaled ||= ScaledMatrix.new(self)
    end

    private def fill_rows(scanners : Array(ValueScanner), buffer : Slice(Int32), scratch : Slice(Int32), rows : Int32) : Nil
      scanners.each_with_index do |scanner, column|
        scanner.fill(scratch[0, rows])
        rows.times { |row| buffer[row * column_count + column] = scratch[row] }
      end
    end
  end

  class ScaledMatrix
    def initialize(@raw : Matrix)
      @tracks = @raw.tracks
    end

    def column_count : Int32
      @raw.column_count
    end

    def read_rows_into(chromosome : String, start : Int, buffer : Slice(Float64)) : Int32
      raise ArgumentError.new("row buffer size must be a multiple of column count") unless buffer.size % column_count == 0
      raw = Slice(Int32).new(buffer.size)
      rows = @raw.read_rows_into(chromosome, start, raw)
      convert(raw, buffer, rows)
      rows
    end

    def scan_rows(region : Region, buffer : Slice(Float64), & : Int64, Slice(Float64), Int32 -> Nil) : Nil
      raw = Slice(Int32).new(buffer.size)
      @raw.scan_rows(region, raw) do |position, data, rows|
        convert(data, buffer, rows)
        yield position, buffer[0, rows * column_count], rows
      end
    end

    private def convert(raw : Slice(Int32), output : Slice(Float64), rows : Int32) : Nil
      rows.times do |row|
        @tracks.each_with_index do |track, column|
          index = row * column_count + column
          output[index] = raw[index].to_f64 / track.metadata.denominator
        end
      end
    end
  end

  class File
    def matrix(names : Enumerable(String)) : Matrix
      Matrix.new(names.map { |name| track(name) })
    end
  end
end
