module D4
  class Error < Exception; end

  class FormatError < Error; end

  class UnexpectedEOFError < FormatError; end

  class ClosedError < Error; end

  class UnknownChromosomeError < Error; end

  class TrackSelectionError < Error; end

  class UnsupportedFeatureError < Error; end

  class AllocationLimitError < Error; end

  class IncompleteHistogramError < Error; end

  class MissingIndexError < Error; end

  class CorruptIndexError < FormatError; end

  class IndexPrecisionError < Error; end

  class HTTPError < Error; end

  class RangeNotSupportedError < HTTPError; end

  class SourceChangedError < HTTPError; end

  # Compatibility name for callers of the former d4binding wrapper.
  D4Error = Error
end
