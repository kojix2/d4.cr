require "./d4/version"
require "./d4/lib_d4"
require "./d4/types"
require "./d4/file"
require "./d4/query"
require "./d4/writer"

# D4 format library for Crystal
#
# D4 is a format designed to store quantitative data associated with genomic intervals.
# It provides efficient compression and fast random access for depth data and similar
# genomic quantitative information.
#
# ## Usage
#
# ### Reading D4 files
#
# ```
# # Open and read a D4 file
# D4::File.open("data.d4") do |d4|
#   puts d4.chromosomes
#
#   # Get values for a region
#   values = d4.values("chr1", 1000_u32, 2000_u32)
#   puts "Mean depth: #{values.sum / values.size}"
#
#   # Query intervals with a block
#   d4.query("chr1", 1000_u32, 2000_u32) do |interval|
#     puts "#{interval.left}-#{interval.right}: #{interval.value}"
#   end
# end
# ```
#
# ### Writing D4 files
#
# ```
# # Create a new D4 file
# D4::Writer.new("output.d4") do |writer|
#   # Set up chromosomes
#   chromosomes = {"chr1" => 1000_u32, "chr2" => 2000_u32}
#   writer.set_chromosomes(chromosomes)
#
#   # Write values
#   values = [1, 2, 3, 4, 5]
#   writer.write_values("chr1", 0_u32, values)
# end
# ```
module D4
  # Convenience method to open a D4 file for reading
  def self.open(path : String, mode : String = "r")
    File.open(path, mode)
  end

  # Convenience method to open a D4 file with a block
  def self.open(path : String, mode : String = "r", &block : File -> T) forall T
    File.open(path, mode, &block)
  end

  # Create a new D4 writer
  def self.writer(path : String)
    Writer.new(path)
  end

  # Create a new D4 writer with a block
  def self.writer(path : String, &block : Writer -> T) forall T
    writer = Writer.new(path)
    begin
      yield writer
    ensure
      writer.close unless writer.closed?
    end
  end

  # Build SFI index for a D4 file
  def self.build_index(path : String)
    File.build_index(path)
  end

  # Clear any D4 library errors
  def self.clear_errors
    LibD4.d4_error_clear
  end

  # Get the current D4 library error number
  def self.error_number
    LibD4.d4_error_num
  end
end
