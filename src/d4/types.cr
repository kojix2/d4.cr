module D4
  enum DictType
    SimpleRange
    ValueMap
  end

  enum Rounding
    NearestAway
    Floor
    Ceil
    TowardZero
  end

  class Chromosome
    getter name : String
    getter size : Int64

    def initialize(@name : String, @size : Int64)
      raise ArgumentError.new("chromosome name must not be empty") if @name.empty?
      raise ArgumentError.new("chromosome size must be non-negative") if @size < 0
      raise UnsupportedFeatureError.new("D4 supports chromosome sizes up to UInt32::MAX") if @size > UInt32::MAX
    end
  end

  class Region
    getter chromosome : String
    getter start : Int64
    getter stop : Int64

    def initialize(@chromosome : String, @start : Int64, @stop : Int64)
      raise ArgumentError.new("region start must not exceed stop") if @start > @stop
      raise ArgumentError.new("region coordinates must be non-negative") if @start < 0
    end

    def initialize(@chromosome : String, range : Range(B, E)) forall B, E
      @start = range.begin.to_i64
      last = range.end.to_i64
      raise ArgumentError.new("inclusive region end is too large") if !range.excludes_end? && last == Int64::MAX
      @stop = last + (range.excludes_end? ? 0 : 1)
      raise ArgumentError.new("region start must not exceed stop") if @start > @stop
      raise ArgumentError.new("region coordinates must be non-negative") if @start < 0
    end

    def length : Int64
      @stop - @start
    end
  end

  class Interval(T)
    getter left : Int64
    getter right : Int64
    getter value : T

    def initialize(@left : Int64, @right : Int64, @value : T)
      raise ArgumentError.new("interval start must not exceed stop") if @left > @right
      raise ArgumentError.new("interval coordinates must be non-negative") if @left < 0
    end

    def start : Int64
      @left
    end

    def stop : Int64
      @right
    end

    def length : Int64
      @right - @left
    end

    def to_s(io : IO) : Nil
      io << @left << '-' << @right << ':' << @value
    end
  end

  alias RawInterval = Interval(Int32)

  class Dictionary
    getter type : DictType
    getter low : Int32
    getter high : Int32
    @reverse : Hash(Int32, UInt32)?

    def initialize(@low : Int32, @high : Int32)
      raise ArgumentError.new("dictionary range must not be empty") if @low >= @high
      count = @high.to_i64 - @low.to_i64
      raise ArgumentError.new("dictionary size must be a power of two") unless power_of_two?(count)
      @type = DictType::SimpleRange
      @values = nil
      @reverse = nil
    end

    def initialize(values : Array(Int32))
      raise ArgumentError.new("dictionary must contain at least one value") if values.empty?
      raise ArgumentError.new("dictionary size must be a power of two") unless power_of_two?(values.size.to_i64)
      @type = DictType::ValueMap
      @values = values.dup
      @reverse = nil
      @low = 0
      @high = 0
    end

    def bit_width : Int32
      count = @type.simple_range? ? (@high.to_i64 - @low.to_i64) : @values.not_nil!.size.to_i64
      width = 0
      while count > 1
        count >>= 1
        width += 1
      end
      width
    end

    def first_value : Int32
      @type.simple_range? ? @low : @values.not_nil!.first
    end

    def values : Array(Int32)?
      @values.try(&.dup)
    end

    def decode(code : UInt32) : Int32?
      if @type.simple_range?
        value = @low.to_i64 + code.to_i64
        return nil if value >= @high
        value.to_i32
      else
        @values.not_nil![code.to_i]?
      end
    end

    def encode(value : Int32) : UInt32?
      if @type.simple_range?
        return nil if value < @low || value >= @high
        (value - @low).to_u32
      else
        reverse = @reverse ||= begin
          mapping = Hash(Int32, UInt32).new
          @values.not_nil!.each_with_index { |item, index| mapping[item] ||= index.to_u32 }
          mapping
        end
        reverse[value]?
      end
    end

    private def power_of_two?(value : Int64) : Bool
      value > 0 && (value & (value - 1)) == 0
    end
  end

  class Metadata
    getter dictionary : Dictionary
    getter denominator : Float64

    def initialize(chromosomes : Array(Chromosome), @dictionary : Dictionary, @denominator : Float64 = 1.0)
      raise ArgumentError.new("denominator must be finite and positive") unless @denominator.finite? && @denominator > 0
      @chromosomes = chromosomes.dup
      @by_name = Hash(String, Chromosome).new
      @chromosomes.each do |chromosome|
        raise ArgumentError.new("duplicate chromosome #{chromosome.name}") if @by_name.has_key?(chromosome.name)
        @by_name[chromosome.name] = chromosome
      end
    end

    def chromosomes : Array(Chromosome)
      @chromosomes.dup
    end

    def chromosome_count : Int32
      @chromosomes.size
    end

    def chromosome?(name : String) : Chromosome?
      @by_name[name]?
    end

    def chromosome(name : String) : Chromosome
      chromosome?(name) || raise UnknownChromosomeError.new("chromosome #{name.inspect} was not found")
    end

    def chromosome_size?(name : String) : Int64?
      chromosome?(name).try(&.size)
    end

    def chromosome_size(name : String) : Int64
      chromosome(name).size
    end

    def has_chromosome?(name : String) : Bool
      @by_name.has_key?(name)
    end
  end

  class ReadOptions
    getter max_materialized_bytes : Int64
    getter max_metadata_bytes : Int64
    getter max_decoded_frame_bytes : Int64

    def initialize(@max_materialized_bytes : Int64 = 64_i64 * 1024 * 1024,
                   @max_metadata_bytes : Int64 = 4_i64 * 1024 * 1024,
                   @max_decoded_frame_bytes : Int64 = 32_i64 * 1024 * 1024)
      raise ArgumentError.new("read limits must be positive") if @max_materialized_bytes <= 0 || @max_metadata_bytes <= 0 || @max_decoded_frame_bytes <= 0
    end
  end

  class WriteOptions
    getter overwrite : Bool
    getter compression : Compression
    getter indexes : Array(IndexKind)

    def initialize(@overwrite : Bool = false, @compression : Compression = Compression.none,
                   @indexes : Array(IndexKind) = [] of IndexKind); end
  end

  class Compression
    getter level : Int32?

    private def initialize(@level : Int32?); end

    def self.none : Compression
      new(nil)
    end

    def self.deflate(level : Int32 = 5) : Compression
      raise ArgumentError.new("DEFLATE level must be in 0..9") unless 0 <= level <= 9
      new(level)
    end
  end

  class Summary
    getter length : Int64
    getter sum : Int64
    getter min : Int32?
    getter max : Int32?

    def initialize(@length : Int64, @sum : Int64, @min : Int32?, @max : Int32?); end

    def mean : Float64?
      return nil if @length == 0
      @sum.to_f64 / @length
    end
  end
end
