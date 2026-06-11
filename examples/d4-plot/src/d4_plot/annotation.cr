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
    FEATURE_TYPES       = {"gene", "transcript", "mrna", "exon"}
    MAX_IN_MEMORY_BYTES = 32 * 1024 * 1024

    getter path : String
    getter size : Int32
    getter? indexed : Bool

    @cache_key : String?
    @cache_features : Array(AnnotationFeature)

    def initialize(@path : String, features : Array(AnnotationFeature), @indexed : Bool = false)
      @cache_key = nil
      @cache_features = [] of AnnotationFeature
      @features_by_chromosome = Hash(String, Array(AnnotationFeature)).new { |hash, key| hash[key] = [] of AnnotationFeature }
      features.each do |feature|
        @features_by_chromosome[feature.chromosome] << feature
      end
      @features_by_chromosome.each_value(&.sort_by! { |feature| {feature.start1, feature.end1} })
      @size = features.size
    end

    def self.indexed(path : String)
      new(path, [] of AnnotationFeature, indexed: true)
    end

    def self.load(path : String)
      return indexed(path) if tabix_indexed?(path)
      validate_in_memory_size(path)

      features = [] of AnnotationFeature
      each_line(path) do |line|
        if feature = parse_line(line)
          features << feature
        end
      end
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
      if region.length > max_region_size
        return AnnotationTrack.notice("Zoom in to show gene annotations")
      end

      features = overlapping(region, limit)
      return AnnotationTrack.too_many(limit) if features.size > limit

      AnnotationTrack.features(features)
    end

    def description
      indexed? ? "tabix indexed" : "#{size} features"
    end

    private def features_for(chromosome)
      @features_by_chromosome[chromosome]? ||
        chromosome_aliases(chromosome).compact_map { |name| @features_by_chromosome[name]? }.first? ||
        [] of AnnotationFeature
    end

    private def chromosome_aliases(chromosome)
      if chromosome.starts_with?("chr")
        [chromosome[3..]?]
      else
        ["chr#{chromosome}"]
      end
    end

    private def overlapping_with_tabix(region, limit)
      key = "#{region.chromosome}:#{region.start1}-#{region.end1}:#{limit}"
      return @cache_features if @cache_key == key

      features = query_tabix(region, limit)
      @cache_key = key
      @cache_features = features
      features
    end

    private def query_tabix(region, limit)
      chromosome_names(region.chromosome).each do |chromosome|
        features = query_tabix_region(chromosome, region.start1, region.end1, limit)
        return features unless features.empty?
      end

      [] of AnnotationFeature
    end

    private def chromosome_names(chromosome)
      [chromosome] + chromosome_aliases(chromosome).compact
    end

    private def query_tabix_region(chromosome, start1, end1, limit)
      output = IO::Memory.new
      error = IO::Memory.new
      status = Process.run("tabix", {@path, "#{chromosome}:#{start1}-#{end1}"}, output: output, error: error)
      return [] of AnnotationFeature unless status.success?

      features = [] of AnnotationFeature
      query_limit = limit + 1
      output.to_s.each_line do |line|
        if feature = self.class.parse_line(line)
          features << feature
          break if features.size >= query_limit
        end
      end
      features
    rescue File::NotFoundError
      raise "tabix command not found. Install tabix or open a small unindexed annotation file."
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
      return if line.empty? || line.starts_with?("#")

      fields = line.split('\t')
      return unless fields.size >= 9

      kind = fields[2].downcase
      return unless FEATURE_TYPES.includes?(kind)

      start1 = fields[3].to_u32?
      end1 = fields[4].to_u32?
      return unless start1 && end1

      AnnotationFeature.new(
        fields[0],
        start1,
        end1,
        kind,
        feature_name(parse_attributes(fields[8])),
        fields[6] == "." ? nil : fields[6]
      )
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
        attributes["ID"]? ||
        attributes["Parent"]?
    end
  end
end
