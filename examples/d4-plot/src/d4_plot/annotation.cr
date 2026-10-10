require "compress/gzip"
require "./region"

module D4Plot
  struct AnnotationFeature
    getter chromosome : String
    getter start1 : UInt32
    getter end1 : UInt32
    getter kind : String
    getter name : String?
    getter strand : String?

    def initialize(@chromosome : String, @start1 : UInt32, @end1 : UInt32, @kind : String, @name : String?, @strand : String?); end
  end

  struct AnnotationTrack
    getter features : Array(AnnotationFeature)
    getter notice : String?

    def initialize(@features : Array(AnnotationFeature), @notice : String? = nil); end

    def self.features(features : Array(AnnotationFeature))
      new(features)
    end

    def self.notice(message : String)
      new([] of AnnotationFeature, message)
    end

    def self.too_many(limit : Int32)
      notice("Too many annotations (>#{limit}); zoom in")
    end

    def empty?
      @features.empty? && @notice.nil?
    end
  end

  class AnnotationIndex
    FEATURE_TYPES          = {"gene", "transcript", "mrna", "exon"}
    MAX_IN_MEMORY_BYTES    = 32 * 1024 * 1024
    MAX_IN_MEMORY_FEATURES = 100_000

    getter path : String
    getter size : Int32
    getter? indexed : Bool
    getter chromosome_names : Array(String)

    @cache_key : String?
    @cache_features : Array(AnnotationFeature)

    def initialize(@path : String, features : Array(AnnotationFeature), @indexed : Bool = false, chromosome_names : Array(String)? = nil)
      @cache_key = nil
      @cache_features = [] of AnnotationFeature
      @features_by_chromosome = Hash(String, Array(AnnotationFeature)).new { |hash, key| hash[key] = [] of AnnotationFeature }
      features.each do |feature|
        @features_by_chromosome[feature.chromosome] << feature
      end
      @features_by_chromosome.each_value(&.sort_by! { |feature| {feature.start1, feature.end1} })
      @size = features.size
      @chromosome_names = chromosome_names || @features_by_chromosome.keys
    end

    def self.indexed(path : String)
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run("tabix", {"-l", path}, output: output, error: error)
      raise "Could not read annotation index: #{error}" unless status.success?
      new(path, [] of AnnotationFeature, indexed: true, chromosome_names: output.to_s.lines)
    rescue File::NotFoundError
      raise "tabix command not found. Install tabix to read indexed annotations."
    end

    def self.load(path : String)
      return indexed(path) if tabix_indexed?(path)
      validate_in_memory_size(path)

      features = [] of AnnotationFeature
      bytes = 0_i64
      each_line(path) do |line|
        bytes += line.bytesize + 1
        if bytes > MAX_IN_MEMORY_BYTES || features.size >= MAX_IN_MEMORY_FEATURES
          raise "Annotation data exceeds the in-memory limit. Use bgzip and a tabix index for large annotations."
        end
        if feature = parse_line(line)
          features << feature
        end
      end
      raise "No supported features found. Open GFF3/GTF genes, transcripts or exons, or BED intervals." if features.empty?
      new(path, features)
    end

    def overlapping(region : Region, limit : Int32)
      return overlapping_with_tabix(region, limit) if indexed?

      features = features_for(region.chromosome)
      return [] of AnnotationFeature if features.empty?

      matches = [] of AnnotationFeature
      query_limit = limit + 1
      features.each do |feature|
        break if feature.start1 > region.end1
        next if feature.end1 < region.start1

        matches << feature
        break if matches.size >= query_limit
      end
      matches
    end

    def track_for(region : Region, max_region_size : UInt32, limit : Int32)
      unless @chromosome_names.includes?(region.chromosome)
        return AnnotationTrack.notice("No chromosome #{region.chromosome.inspect} in annotations; names must match exactly (including chr prefix).")
      end
      if region.length > max_region_size
        return AnnotationTrack.notice("Zoom in to show gene annotations")
      end

      features = overlapping(region, limit)
      return AnnotationTrack.too_many(limit) if features.size > limit
      return AnnotationTrack.notice("No overlapping annotations in this region") if features.empty?

      AnnotationTrack.features(features)
    end

    def description
      indexed? ? "tabix indexed" : "#{size} features"
    end

    private def features_for(chromosome)
      @features_by_chromosome[chromosome]? || [] of AnnotationFeature
    end

    private def overlapping_with_tabix(region, limit)
      key = "#{region.chromosome}:#{region.start1}-#{region.end1}:#{limit}"
      return @cache_features if @cache_key == key

      features = query_tabix_region(region.chromosome, region.start1, region.end1, limit)
      @cache_key = key
      @cache_features = features
      features
    end

    private def query_tabix_region(chromosome, start1, end1, limit)
      features = [] of AnnotationFeature
      query_limit = limit + 1
      process = Process.new("tabix", {@path, "#{chromosome}:#{start1}-#{end1}"}, output: Process::Redirect::Pipe, error: Process::Redirect::Close)
      process.output.each_line do |line|
        if feature = self.class.parse_line(line)
          features << feature
          if features.size >= query_limit
            process.terminate unless process.terminated?
            break
          end
        end
      end
      status = process.wait
      raise "tabix could not read annotations; check that the compressed file and index match." unless status.success? || features.size >= query_limit
      features
    rescue File::NotFoundError
      raise "tabix command not found. Install tabix or open a small unindexed annotation file."
    ensure
      if process
        unless status
          process.terminate unless process.terminated?
          process.wait
        end
        process.close
      end
    end

    private def self.tabix_indexed?(path)
      path.ends_with?(".gz") && (File.exists?("#{path}.tbi") || File.exists?("#{path}.csi"))
    end

    private def self.validate_in_memory_size(path)
      size = File.size(path)
      return if size <= MAX_IN_MEMORY_BYTES

      raise "Annotation file is too large for in-memory loading. Compress with bgzip and create a .tbi/.csi index."
    end

    private def self.each_line(path, &)
      File.open(path) do |file|
        if path.ends_with?(".gz")
          Compress::Gzip::Reader.open(file) do |gzip|
            gzip.each_line { |line| yield line }
          end
        else
          file.each_line { |line| yield line }
        end
      end
    end

    def self.parse_line(line)
      return if line.empty? || line.starts_with?(/^(#|track |browser )/)

      fields = line.split('\t')
      if fields.size >= 3 && fields[1].to_u32? && fields[2].to_u32?
        return parse_bed(fields)
      end
      parse_gff(fields)
    end

    private def self.parse_gff(fields)
      return unless fields.size >= 9

      kind = fields[2].downcase
      return unless FEATURE_TYPES.includes?(kind)

      start1 = fields[3].to_u32?
      end1 = fields[4].to_u32?
      return unless start1 && end1 && start1 > 0 && end1 >= start1

      AnnotationFeature.new(
        fields[0],
        start1,
        end1,
        kind,
        feature_name(parse_attributes(fields[8])),
        fields[6] == "." ? nil : fields[6]
      )
    end

    private def self.parse_bed(fields)
      start0 = fields[1].to_u32
      end0 = fields[2].to_u32
      return if end0 <= start0
      strand = fields[5]?
      strand = nil unless strand == "+" || strand == "-"
      name = fields[3]?
      name = nil if name == "."
      AnnotationFeature.new(fields[0], start0 + 1, end0, "region", name, strand)
    end

    private def self.parse_attributes(text)
      attributes = Hash(String, String).new
      text.split(';').each do |part|
        parse_attribute(part.strip, attributes)
      end
      attributes
    end

    private def self.parse_attribute(part, attributes)
      return if part.empty?

      if key_value = part.split('=', 2)
        if key_value.size == 2
          attributes[key_value[0]] = key_value[1]
          return
        end
      end

      if match = part.match(/^(\S+)\s+"?([^"]+)"?$/)
        attributes[match[1]] = match[2]
      end
    end

    private def self.feature_name(attributes)
      attributes["Name"]? ||
        attributes["gene_name"]? ||
        attributes["gene"]? ||
        attributes["transcript_name"]? ||
        attributes["gene_id"]? ||
        attributes["transcript_id"]? ||
        attributes["ID"]? ||
        attributes["Parent"]?
    end
  end
end
