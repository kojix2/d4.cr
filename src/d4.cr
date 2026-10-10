require "./d4/version"
require "./d4/errors"
require "./d4/types"
require "./d4/source"
require "./d4/format"
require "./d4/index"
require "./d4/track"
require "./d4/file"
require "./d4/stats"
require "./d4/bins"
require "./d4/scaled"
require "./d4/matrix"
require "./d4/reducers"
require "./d4/query"
require "./d4/writer"
require "./d4/index_builder"

# D4 format library for Crystal
#
# D4 is a format designed to store quantitative data associated with genomic intervals.
# It provides efficient compression and fast random access for depth data and similar
# genomic quantitative information.
#
# ## Usage
#
# ### Reading D4 files
#
# ```
# D4.open("data.d4") do |file|
#   puts file.chromosomes.map(&.name)
#   puts file.mean("chr1", 1000, 2000)
#   file.each_interval("chr1", 1000, 2000) do |interval|
#     puts "#{interval.left}-#{interval.right}: #{interval.value}"
#   end
# end
# ```
#
# ### Writing D4 files
#
# ```
# D4.create("output.d4", chromosomes: [D4::Chromosome.new("chr1", 1000_i64)],
#   dictionary: D4::Dictionary.new(0_i32, 8_i32)) do |writer|
#   writer.write_values("chr1", 0, [1_i32, 2_i32, 3_i32])
# end
# ```
module D4
  # Convenience method to open a D4 file for reading
  def self.open(path : String | Path, *, track : String? = nil, options : ReadOptions = ReadOptions.new)
    File.open(path, track: track, options: options)
  end

  # Convenience method to open a D4 file with a block
  def self.open(path : String | Path, *, track : String? = nil, options : ReadOptions = ReadOptions.new, & : File -> T) forall T
    File.open(path, track: track, options: options) do |file|
      yield file
    end
  end

  def self.open(source : Source, *, sync_close : Bool = false, track : String? = nil, options : ReadOptions = ReadOptions.new)
    File.open(source, sync_close: sync_close, track: track, options: options)
  end

  def self.open(source : Source, *, sync_close : Bool = false, track : String? = nil, options : ReadOptions = ReadOptions.new, & : File -> T) forall T
    File.open(source, sync_close: sync_close, track: track, options: options) do |file|
      yield file
    end
  end

  def self.open(io : IO, *, sync_close : Bool = false, track : String? = nil, options : ReadOptions = ReadOptions.new)
    source = IOSource.new(io, sync_close)
    begin
      File.open(source, sync_close: true, track: track, options: options)
    rescue error
      source.close
      raise error
    end
  end

  def self.open(io : IO, *, sync_close : Bool = false, track : String? = nil, options : ReadOptions = ReadOptions.new, & : File -> T) : T forall T
    file = open(io, sync_close: sync_close, track: track, options: options)
    begin
      yield file
    ensure
      file.close
    end
  end

  # Create a new D4 writer
  def self.writer(path : String | Path, *, options : WriteOptions = WriteOptions.new)
    Writer.new(path, options)
  end

  # Create a new D4 writer with a block
  def self.writer(path : String | Path, *, options : WriteOptions = WriteOptions.new, & : Writer -> T) forall T
    writer = Writer.new(path, options)
    begin
      result = yield writer
      writer.finish
      result
    rescue error
      writer.abort
      raise error
    end
  end

  def self.create(path : String | Path, *, chromosomes : Array(Chromosome),
                  dictionary : Dictionary = Dictionary.new(0_i32, 64_i32), denominator : Float64 = 1.0,
                  default_value : Int32 = 0_i32, options : WriteOptions = WriteOptions.new) : Writer
    writer = Writer.new(path, options)
    writer.configure(chromosomes, dictionary, denominator, default_value)
    writer
  end

  def self.create(path : String | Path, *, chromosomes : Array(Chromosome),
                  dictionary : Dictionary = Dictionary.new(0_i32, 64_i32), denominator : Float64 = 1.0,
                  default_value : Int32 = 0_i32, options : WriteOptions = WriteOptions.new, & : Writer -> T) : T forall T
    writer = create(path, chromosomes: chromosomes, dictionary: dictionary,
      denominator: denominator, default_value: default_value, options: options)
    begin
      result = yield writer
      writer.finish
      result
    rescue error
      writer.abort
      raise error
    end
  end
end
