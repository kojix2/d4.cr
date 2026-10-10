require "spec"
require "http/server"
require "../src/d4/http"

describe D4::HTTPSource do
  it "reads a D4 through bounded, cached byte ranges" do
    data = File.read(File.join(__DIR__, "fixtures", "rust-input-10nt.d4")).to_slice
    requests = 0
    server = HTTP::Server.new do |context|
      requests += 1
      range = context.request.headers["Range"]?
      if match = range.try { |value| /\Abytes=(\d+)-(\d+)\z/.match(value) }
        first = match[1].to_i
        last = match[2].to_i
        count = last - first + 1
        context.response.status_code = 206
        context.response.headers["Content-Range"] = "bytes #{first}-#{last}/#{data.size}"
        context.response.content_length = count
        context.response.write(data[first, count])
      else
        context.response.status_code = 200
      end
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      source = D4::HTTPSource.new("http://127.0.0.1:#{address.port}/data.d4", block_size: 4096)
      D4.open(source, sync_close: true) do |file|
        file.values("chr", 0, 10).should eq(D4.open(File.join(__DIR__, "fixtures", "rust-input-10nt.d4")) { |local| local.values("chr", 0, 10) })
        file.value("chr", 4).should eq(file.value("chr", 4))
      end
      requests.should be < 20
    ensure
      server.close
    end
  end

  it "rejects servers that ignore Range" do
    server = HTTP::Server.new do |context|
      context.response.status_code = 200
      context.response.print "not a range"
    end
    address = server.bind_tcp("127.0.0.1", 0)
    spawn { server.listen }
    begin
      expect_raises(D4::RangeNotSupportedError) { D4::HTTPSource.new("http://127.0.0.1:#{address.port}/data.d4") }
    ensure
      server.close
    end
  end

  it "uses embedded indexes over HTTP and detects a changed ETag" do
    temporary = File.tempfile("d4-http-index", ".d4")
    path = temporary.path
    temporary.close
    File.delete(path)
    begin
      D4.create(path, chromosomes: [D4::Chromosome.new("chr", 131_072_i64)],
        dictionary: D4::Dictionary.new([0_i32]),
        options: D4::WriteOptions.new(indexes: [D4::IndexKind::SecondaryFrames, D4::IndexKind::Sum])) do |writer|
        20_000.times { |position| writer.write_value("chr", position, position.even? ? 1_i32 : 2_i32) }
      end
      data = File.read(path).to_slice
      requests = 0
      version = "v1"
      server = HTTP::Server.new do |context|
        requests += 1
        match = /\Abytes=(\d+)-(\d+)\z/.match(context.request.headers["Range"]) || raise "invalid Range header"
        first = match[1].to_i
        last = match[2].to_i
        context.response.status_code = 206
        context.response.headers["Content-Range"] = "bytes #{first}-#{last}/#{data.size}"
        context.response.headers["ETag"] = version
        context.response.content_length = last - first + 1
        context.response.write(data[first, last - first + 1])
      end
      address = server.bind_tcp("127.0.0.1", 0)
      spawn { server.listen }
      begin
        source = D4::HTTPSource.new("http://127.0.0.1:#{address.port}/indexed.d4", block_size: 4096, cache_blocks: 8)
        D4.open(source, sync_close: true) do |file|
          file.value("chr", 19_999).should eq(2_i32)
          file.sum("chr", 0, 131_072, index: D4::IndexPolicy::Require).should eq(30_000_i64)
          requests.should be < 40
          version = "v2"
          expect_raises(D4::SourceChangedError) { file.value("chr", 0) }
        end
      ensure
        server.close
      end
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end
