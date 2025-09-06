require "./lib_d4"

module D4
  # D4 specific exception
  class D4Error < Exception
    def initialize(message : String? = nil)
      super(message || get_d4_error_message)
    end

    private def get_d4_error_message
      buffer = Bytes.new(256)
      LibD4.d4_error_message(buffer.to_unsafe.as(LibC::Char*), buffer.size)
      String.new(buffer.to_unsafe)
    end
  end

  # Represents a genomic interval with a value
  struct Interval
    getter left : UInt32
    getter right : UInt32
    getter value : Int32

    def initialize(@left : UInt32, @right : UInt32, @value : Int32)
    end

    def initialize(lib_interval : LibD4::Interval)
      @left = lib_interval.left
      @right = lib_interval.right
      @value = lib_interval.value
    end

    def to_lib_interval
      LibD4::Interval.new(left: @left, right: @right, value: @value)
    end

    def length
      @right - @left
    end

    def to_s(io : IO) : Nil
      io << "#{@left}-#{@right}:#{@value}"
    end
  end

  # Dictionary types for D4 files
  enum DictType
    SimpleRange
    ValueMap

    def to_lib_dict_type
      case self
      in .simple_range?
        LibD4::DictType::SimpleRange
      in .value_map?
        LibD4::DictType::ValueMap
      end
    end

    def self.from_lib_dict_type(lib_type : LibD4::DictType)
      case lib_type
      in .simple_range?
        SimpleRange
      in .value_map?
        ValueMap
      end
    end
  end

  # Metadata for D4 files
  class Metadata
    getter chromosomes : Hash(String, UInt32)
    getter dict_type : DictType
    getter denominator : Float64

    def initialize(@chromosomes : Hash(String, UInt32), @dict_type : DictType, @denominator : Float64 = 1.0)
    end

    def initialize(lib_metadata : LibD4::FileMetadata)
      @chromosomes = Hash(String, UInt32).new
      @dict_type = DictType.from_lib_dict_type(lib_metadata.dict_type)
      @denominator = lib_metadata.denominator

      # Extract chromosome information
      chrom_count = lib_metadata.chrom_count.to_i
      chrom_names = lib_metadata.chrom_name
      chrom_sizes = lib_metadata.chrom_size

      chrom_count.times do |i|
        name = String.new(chrom_names[i])
        size = chrom_sizes[i]
        @chromosomes[name] = size
      end
    end

    def chromosome_count
      @chromosomes.size
    end

    def has_chromosome?(name : String)
      @chromosomes.has_key?(name)
    end

    def chromosome_size(name : String)
      @chromosomes[name]?
    end
  end

  # Helper methods for error checking
  private def self.check_result(result : Int32, message : String)
    if result < 0
      raise D4Error.new(message)
    end
    result
  end

  private def self.check_ssize_result(result : LibC::SSizeT, message : String)
    if result < 0
      raise D4Error.new(message)
    end
    result
  end

  private def self.check_pointer(pointer : Void*, message : String)
    if pointer.null?
      raise D4Error.new(message)
    end
    pointer
  end
end
