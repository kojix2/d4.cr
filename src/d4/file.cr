module D4
  class File
    @tracks : Hash(String, Track)

    getter source : Source
    getter options : ReadOptions

    def self.open(path : String | Path, *, track : String? = nil, options : ReadOptions = ReadOptions.new) : File
      source = LocalSource.new(path)
      begin
        new(source, true, track, options)
      rescue error
        source.close
        raise error
      end
    end

    def self.open(path : String | Path, *, track : String? = nil, options : ReadOptions = ReadOptions.new, & : File -> T) : T forall T
      file = open(path, track: track, options: options)
      begin
        yield file
      ensure
        file.close
      end
    end

    def self.open(source : Source, *, sync_close : Bool = false, track : String? = nil, options : ReadOptions = ReadOptions.new) : File
      new(source, sync_close, track, options)
    end

    def self.open(source : Source, *, sync_close : Bool = false, track : String? = nil, options : ReadOptions = ReadOptions.new, & : File -> T) : T forall T
      file = open(source, sync_close: sync_close, track: track, options: options)
      begin
        yield file
      ensure
        file.close
      end
    end

    def initialize(@source : Source, @owns_source : Bool, requested_track : String?, @options : ReadOptions)
      @closed = false
      root = Format::Directory.open_root(@source, @options.max_metadata_bytes)
      @tracks = load_tracks(root)
      @tracks.each_value(&.bind_owner(self))
      raise FormatError.new("D4 container contains no tracks") if @tracks.empty?
      @selected_track_name = requested_track
      if requested_track
        raise TrackSelectionError.new("track #{requested_track.inspect} was not found") unless @tracks.has_key?(requested_track)
      end
    end

    def close : Nil
      return if @closed
      @source.close if @owns_source
      @closed = true
    end

    def closed? : Bool
      @closed
    end

    def track_names : Array(String)
      check_open
      @tracks.keys
    end

    def each_track(& : Track -> Nil) : Nil
      check_open
      @tracks.each_value { |track| yield track }
    end

    def each_track
      check_open
      @tracks.each_value
    end

    def track?(name : String) : Track?
      check_open
      @tracks[name]?
    end

    def track(name : String) : Track
      track?(name) || raise TrackSelectionError.new("track #{name.inspect} was not found")
    end

    def default_track : Track
      check_open
      if name = @selected_track_name
        return @tracks[name]
      end
      return @tracks.values.first if @tracks.size == 1
      raise TrackSelectionError.new("this D4 file has multiple tracks; select one with File#track")
    end

    def metadata : Metadata
      default_track.metadata
    end

    def chromosomes : Array(Chromosome)
      default_track.chromosomes
    end

    def chromosome_size(name : String) : Int64
      default_track.chromosome_size(name)
    end

    def chromosome_size?(name : String) : Int64?
      default_track.chromosome_size?(name)
    end

    def has_chromosome?(name : String) : Bool
      default_track.has_chromosome?(name)
    end

    def value(chromosome : String, position : Int) : Int32
      default_track.value(chromosome, position)
    end

    def values(chromosome : String, start : Int = 0, stop : Int? = nil) : Array(Int32)
      default_track.values(chromosome, start, stop)
    end

    def values(region : Region) : Array(Int32)
      default_track.values(region)
    end

    def read_values_into(chromosome : String, start : Int, buffer : Slice(Int32)) : Int32
      default_track.read_values_into(chromosome, start, buffer)
    end

    def each_value(chromosome : String, start : Int = 0, stop : Int? = nil, & : Int32 -> Nil) : Nil
      default_track.each_value(chromosome, start, stop) { |value| yield value }
    end

    def each_value(chromosome : String, start : Int = 0, stop : Int? = nil)
      default_track.each_value(chromosome, start, stop)
    end

    def each_interval(chromosome : String, start : Int = 0, stop : Int? = nil, & : RawInterval -> Nil) : Nil
      default_track.each_interval(chromosome, start, stop) { |interval| yield interval }
    end

    def each_interval(chromosome : String, start : Int = 0, stop : Int? = nil)
      default_track.each_interval(chromosome, start, stop)
    end

    def query(chromosome : String, start : Int = 0, stop : Int? = nil) : Array(RawInterval)
      result = Array(RawInterval).new
      each_interval(chromosome, start, stop) { |interval| result << interval }
      result
    end

    def query(chromosome : String, start : Int = 0, stop : Int? = nil, & : RawInterval -> Nil) : Nil
      each_interval(chromosome, start, stop) { |interval| yield interval }
    end

    def query_iter(chromosome : String, start : Int = 0, stop : Int? = nil)
      each_interval(chromosome, start, stop)
    end

    def sum(chromosome : String, start : Int = 0, stop : Int? = nil, *, index : IndexPolicy = IndexPolicy::Auto) : Int64
      default_track.sum(chromosome, start, stop, index: index)
    end

    def sum(region : Region, *, index : IndexPolicy = IndexPolicy::Auto) : Int64
      default_track.sum(region, index: index)
    end

    def mean(chromosome : String, start : Int = 0, stop : Int? = nil, *, index : IndexPolicy = IndexPolicy::Auto) : Float64?
      default_track.mean(chromosome, start, stop, index: index)
    end

    def mean(region : Region, *, index : IndexPolicy = IndexPolicy::Auto) : Float64?
      default_track.mean(region, index: index)
    end

    def summary(chromosome : String, start : Int = 0, stop : Int? = nil) : Summary
      default_track.summary(chromosome, start, stop)
    end

    def summary(region : Region) : Summary
      default_track.summary(region)
    end

    private def load_tracks(root : Format::Directory) : Hash(String, Track)
      tracks = Hash(String, Track).new
      visit_directory(root, "", tracks, Set(Int64).new)
      tracks
    end

    private def visit_directory(directory : Format::Directory, path : String, tracks : Hash(String, Track), visited : Set(Int64)) : Nil
      raise FormatError.new("cyclic D4 directory") unless visited.add?(directory.offset)
      raise FormatError.new("D4 directory nesting limit exceeded") if visited.size > 1024
      if metadata = directory.entry?(".metadata")
        if metadata.stream?
          tracks[path] = Track.new(@source, directory, path, @options)
          return
        end
      end
      directory.entries.each do |entry|
        next unless entry.directory?
        child_path = path.empty? ? entry.name : "#{path}/#{entry.name}"
        child = Format::Directory.open(@source, entry.offset, @options.max_metadata_bytes)
        visit_directory(child, child_path, tracks, visited)
      end
    end

    private def check_open : Nil
      raise ClosedError.new("D4 file is closed") if @closed
    end
  end
end
