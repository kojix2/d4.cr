module D4Plot
  struct Region
    getter chromosome : String
    getter start1 : UInt32
    getter end1 : UInt32

    def initialize(@chromosome : String, @start1 : UInt32, @end1 : UInt32); end

    def self.parse(text : String) : Region?
      if match = text.match(/^([^:]+):(\d+)-(\d+)$/)
        new(match[1], match[2].to_u32, match[3].to_u32)
      end
    end

    def valid?
      @start1 > 0 && @end1 >= @start1
    end

    def start0
      @start1 - 1_u32
    end

    def end0_exclusive
      @end1
    end
  end
end
