require "http/client"
require "../d4"

module D4
  # Seekable remote source backed by validated HTTP byte-range requests.
  # A bounded LRU of blocks is cached; no full-file download is implicit.
  class HTTPSource < Source
    getter size : Int64
    @target : String

    def initialize(url : String | URI, *, @block_size : Int32 = 65_536, @cache_blocks : Int32 = 64,
                   connect_timeout : Time::Span = 10.seconds, read_timeout : Time::Span = 30.seconds)
      raise ArgumentError.new("block_size must be in 1..1048576") unless 1 <= @block_size <= 1_048_576
      raise ArgumentError.new("cache budget must be in 1..33554432 bytes") unless @cache_blocks > 0 && @block_size.to_i64 * @cache_blocks <= 32_i64 * 1024 * 1024
      uri = url.is_a?(URI) ? url : URI.parse(url)
      raise ArgumentError.new("HTTPSource requires http or https") unless {"http", "https"}.includes?(uri.scheme)
      @client = HTTP::Client.new(uri)
      @client.connect_timeout = connect_timeout
      @client.read_timeout = read_timeout
      @target = uri.request_target
      @mutex = Mutex.new
      @closed = false
      @blocks = Hash(Int64, Bytes).new
      @order = Array(Int64).new
      @reuse = Bytes.empty
      @etag = nil.as(String?)
      @size = 0_i64
      begin
        fetch(0_i64, 1, discover: true)
      rescue error
        @client.close
        raise error
      end
    end

    def read_at(offset : Int64, buffer : Bytes) : Int32
      @mutex.synchronize do
        raise ClosedError.new("HTTP source is closed") if @closed
        return 0 if offset < 0 || offset >= @size || buffer.empty?
        copied = 0
        limit = Math.min(buffer.size.to_i64, @size - offset).to_i
        while copied < limit
          position = offset + copied
          start = position // @block_size * @block_size
          if cached = @blocks[start]?
            @order.delete(start)
            @order << start
          else
            if @order.size >= @cache_blocks
              @reuse = @blocks.delete(@order.shift).not_nil!
            end
            cached = fetch(start, Math.min(@block_size.to_i64, @size - start).to_i)
            @blocks[start] = cached
            @order << start
            @reuse = Bytes.empty
          end
          from = (position - start).to_i
          count = Math.min(limit - copied, cached.size - from)
          buffer[copied, count].copy_from(cached[from, count])
          copied += count
        end
        copied
      end
    end

    def close : Nil
      @mutex.synchronize do
        return if @closed
        @closed = true
        @client.close
        @blocks.clear
        @order.clear
        @reuse = Bytes.empty
      end
    end

    def closed? : Bool
      @mutex.synchronize { @closed }
    end

    private def fetch(start : Int64, length : Int32, *, discover : Bool = false) : Bytes
      headers = HTTP::Headers{"Range" => "bytes=#{start}-#{start + length - 1}", "Accept-Encoding" => "identity"}
      headers["If-Match"] = @etag.not_nil! if @etag
      request = HTTP::Request.new("GET", @target, headers)
      @client.exec(request) do |response|
        raise RangeNotSupportedError.new("server ignored HTTP Range") if response.status_code == 200
        raise SourceChangedError.new("remote file changed") if response.status_code == 412
        raise HTTPError.new("HTTP #{response.status_code} for byte range") unless response.status_code == 206
        encoding = response.headers["Content-Encoding"]?
        raise HTTPError.new("encoded byte ranges are unsupported") if encoding && encoding.downcase != "identity"
        content_range = response.headers["Content-Range"]? || raise HTTPError.new("missing Content-Range")
        match = /\Abytes (\d+)-(\d+)\/(\d+)\z/.match(content_range) || raise HTTPError.new("invalid Content-Range")
        first = match[1].to_i64?
        last = match[2].to_i64?
        total = match[3].to_i64?
        raise HTTPError.new("invalid byte-range bounds") unless first == start && last == start + length - 1 && total && total > 0
        raise SourceChangedError.new("remote size changed") if !discover && total != @size
        if etag = @etag
          raise SourceChangedError.new("remote ETag changed") if response.headers["ETag"]? != etag
        else
          @etag = response.headers["ETag"]?
        end
        @size = total if discover
        if content_length = response.headers["Content-Length"]?
          raise HTTPError.new("invalid range length") unless content_length.to_i64? == length
        end
        data = @reuse.size >= length ? @reuse[0, length] : Bytes.new(length)
        io = response.body_io
        io.read_fully(data)
        raise HTTPError.new("range response was too long") unless io.read_byte.nil?
        data
      end
    end
  end
end
