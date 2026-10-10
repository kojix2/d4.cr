module D4
  abstract class Source
    abstract def size : Int64
    abstract def read_at(offset : Int64, buffer : Bytes) : Int32
    abstract def close : Nil
    abstract def closed? : Bool

    def read_exact_at(offset : Int64, buffer : Bytes) : Nil
      raise ArgumentError.new("negative source offset") if offset < 0
      done = 0
      while done < buffer.size
        read = read_at(offset + done, buffer[done, buffer.size - done])
        raise UnexpectedEOFError.new("unexpected end of D4 source at byte #{offset + done}") if read <= 0
        raise FormatError.new("source returned more bytes than requested") if read > buffer.size - done
        done += read
      end
    end
  end

  class MemorySource < Source
    def initialize(data : Bytes, copy : Bool = true)
      @data = copy ? data.dup : data
      @closed = false
    end

    def size : Int64
      @data.size.to_i64
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      raise ClosedError.new("source is closed") if @closed
      return 0 if offset >= @data.size || buffer.empty?
      return 0 if offset < 0
      count = Math.min(buffer.size, @data.size - offset.to_i)
      buffer[0, count].copy_from(@data[offset.to_i, count])
      count
    end

    def close : Nil
      @closed = true
    end

    def closed? : Bool
      @closed
    end
  end

  class LocalSource < Source
    def initialize(path : String | Path)
      @io = ::File.open(path, "rb")
      @mutex = Mutex.new
      @closed = false
      @size = @io.size.to_i64
    end

    def size : Int64
      @size
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      # Positioned bulk reads can run concurrently; small reads avoid PReader setup.
      if buffer.size >= 8_192
        raise ClosedError.new("source is closed") if @closed
        return 0 if offset < 0 || offset >= @size
        count = Math.min(buffer.size.to_i64, @size - offset).to_i
        return @io.read_at(offset, count, &.read(buffer[0, count]))
      end
      @mutex.synchronize do
        raise ClosedError.new("source is closed") if @closed
        return 0 if offset < 0 || offset >= @size || buffer.empty?
        @io.seek(offset, IO::Seek::Set)
        @io.read(buffer)
      end
    end

    def close : Nil
      @mutex.synchronize do
        return if @closed
        @io.close
        @closed = true
      end
    end

    def closed? : Bool
      @closed
    end
  end

  class IOSource < Source
    @size : Int64

    def initialize(@io : IO, @sync_close : Bool = false)
      @mutex = Mutex.new
      @closed = false
      original = @io.pos
      @io.seek(0, IO::Seek::End)
      @size = @io.pos.to_i64
      @io.seek(original, IO::Seek::Set)
    end

    def size : Int64
      @size
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      @mutex.synchronize do
        raise ClosedError.new("source is closed") if @closed
        return 0 if offset < 0 || offset >= @size || buffer.empty?
        @io.seek(offset, IO::Seek::Set)
        @io.read(buffer)
      end
    end

    def close : Nil
      @mutex.synchronize do
        return if @closed
        @io.close if @sync_close
        @closed = true
      end
    end

    def closed? : Bool
      @closed
    end
  end
end
