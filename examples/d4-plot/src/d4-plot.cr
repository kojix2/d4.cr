require "uing"
require "../../../src/d4"

# D4 Plot Application
# A GUI application to visualize D4 format genomic data using UIng

class D4PlotApp
  @main_window : UIng::Window
  @file_button : UIng::Button
  @region_entry : UIng::Entry
  @plot_button : UIng::Button
  @area : UIng::Area
  @handler : UIng::Area::Handler
  @d4_file : D4::File?
  @current_file_path : String?
  @plot_data : Array(Tuple(UInt32, Float64))?

  def initialize
    # Create UI components
    @main_window = UIng::Window.new("D4 Plot Viewer", 800, 600)
    @file_button = UIng::Button.new("Open D4 File")
    @region_entry = UIng::Entry.new
    @plot_button = UIng::Button.new("Plot")
    @handler = UIng::Area::Handler.new
    @area = UIng::Area.new(@handler)
    @d4_file = nil
    @current_file_path = nil
    @plot_data = nil

    setup_ui
    setup_handlers
  end

  private def setup_ui
    # Create layout
    vbox = UIng::Box.new(:vertical)
    vbox.padded = true

    # Top controls
    hbox = UIng::Box.new(:horizontal)
    hbox.padded = true
    hbox.append(@file_button, false)
    hbox.append(@region_entry, true)
    hbox.append(@plot_button, false)

    # Set default region
    @region_entry.text = "chr1:1000-2000"

    # Add to main layout
    vbox.append(hbox, false)
    vbox.append(@area, true)

    @main_window.child = vbox
    @main_window.margined = true

    # Window close handler
    @main_window.on_closing do
      @d4_file.try(&.close)
      UIng.quit
      true
    end
  end

  private def setup_handlers
    # File selection button
    @file_button.on_clicked do
      file_path = @main_window.open_file
      if file_path && !file_path.empty?
        load_d4_file(file_path)
      end
    end

    # Plot button
    @plot_button.on_clicked do
      plot_region
    end

    # Area drawing handler
    @handler.draw do |area, params|
      draw_plot(params.context)
    end
  end

  private def load_d4_file(file_path : String)
    begin
      # Close previous file if open
      @d4_file.try(&.close)

      # Open new D4 file
      @d4_file = D4::File.open(file_path)
      @current_file_path = file_path

      # Update window title
      filename = File.basename(file_path)
      @main_window.title = "D4 Plot Viewer - #{filename}"

      puts "Loaded D4 file: #{file_path}"

      # Get chromosome list for debugging
      if d4 = @d4_file
        chromosomes = d4.chromosomes
        puts "Available chromosomes: #{chromosomes.keys.join(", ")}"
      end
    rescue ex
      puts "Error loading D4 file: #{ex.message}"
      @main_window.msg_box_error("Error", "Failed to load D4 file: #{ex.message}")
    end
  end

  private def parse_region(region_str : String) : Tuple(String, UInt32, UInt32)?
    # Parse region string like "chr1:1000-2000"
    if match = region_str.match(/^([^:]+):(\d+)-(\d+)$/)
      chr = match[1]
      start = match[2].to_u32
      end_pos = match[3].to_u32
      return {chr, start, end_pos}
    end
    nil
  end

  # Downsample data for plotting.
  # Parameters are INTERNAL 0-based half-open [start0, end0_excl)
  # Returned tuple first element is 1-based genomic coordinate (for user display/axis).
  private def downsample_data(chr : String, start0 : UInt32, end0_excl : UInt32, npoints : Int32 = 256) : Array(Tuple(UInt32, Float64))
    return [] of Tuple(UInt32, Float64) unless d4 = @d4_file
    return [] of Tuple(UInt32, Float64) if end0_excl <= start0

    begin
      total_len = end0_excl - start0
      data = [] of Tuple(UInt32, Float64)

      # If region shorter (or equal) than target points, emit per-base values
      if total_len <= npoints.to_u32
        (start0...end0_excl).each do |pos0|
          vals = d4.values(chr, pos0, pos0 + 1_u32)
          v = vals.size > 0 ? vals.sum.to_f / vals.size : 0.0
          # convert to 1-based for display
          data << {pos0 + 1_u32, v}
        end
        return data
      end

      # Compute bin size (integer division, at least 1). Use // to avoid Float64.
      bin_size : UInt32 = (total_len // npoints.to_u32).to_u32
      bin_size = 1_u32 if bin_size == 0

      current = start0
      npoints.times do
        break if current >= end0_excl
        bin_start : UInt32 = current
        # ensure UInt32 explicit types
        bin_end_excl : UInt32 = bin_start + bin_size
        bin_end_excl = end0_excl if bin_end_excl > end0_excl
        # center in 0-based: last included base is bin_end_excl - 1
        center0 = (bin_start + (bin_end_excl - 1_u32)) // 2
        vals = d4.values(chr, bin_start, bin_end_excl)
        mean_value = vals.size > 0 ? vals.sum.to_f / vals.size : 0.0
        data << {center0 + 1_u32, mean_value}
        current = bin_end_excl
      end

      data
    rescue ex
      puts "Error getting data: #{ex.message}"
      [] of Tuple(UInt32, Float64)
    end
  end

  private def plot_region
    return unless @d4_file

    region_str = @region_entry.text
    return unless region_str

    if region = parse_region(region_str)
      chr, start1, end1_inclusive = region
      if start1 == 0 || end1_inclusive < start1
        @main_window.msg_box_error("Error", "Invalid region (must be 1-based inclusive: start >=1 and start <= end)")
        return
      end

      # Convert from user 1-based inclusive to internal 0-based half-open
      start0 = start1 - 1_u32
      end0_excl = end1_inclusive

      puts "Plotting region (user 1-based): #{chr}:#{start1}-#{end1_inclusive} -> internal 0-based half-open: #{start0}-#{end0_excl}"

      @plot_data = downsample_data(chr, start0, end0_excl)

      @area.queue_redraw_all
    else
      @main_window.msg_box_error("Error", "Invalid region format. Use: chr1:1000-2000")
    end
  end

  private def draw_plot(ctx : UIng::Area::Draw::Context)
    # Clear background
    bg_brush = UIng::Area::Draw::Brush.new(:solid, 1.0, 1.0, 1.0, 1.0)
    ctx.fill_path(bg_brush) do |path|
      path.add_rectangle(0, 0, 800, 600)
    end

    return unless data = @plot_data
    return if data.empty?

    # Calculate plot area (with margins)
    margin = 50.0
    plot_width = 800.0 - 2 * margin
    plot_height = 600.0 - 2 * margin

    # Find data ranges
    min_pos = data.first[0].to_f
    max_pos = data.last[0].to_f
    min_val = data.map(&.[1]).min
    max_val = data.map(&.[1]).max

    # Add some padding to value range
    val_range = max_val - min_val
    if val_range == 0
      val_range = 1.0
      min_val -= 0.5
      max_val += 0.5
    else
      padding = val_range * 0.1
      min_val -= padding
      max_val += padding
    end

    # Draw axes
    axis_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.0, 0.0, 1.0)
    ctx.stroke_path(axis_brush, thickness: 1.0) do |path|
      # Y axis
      path.new_figure(margin, margin)
      path.line_to(margin, margin + plot_height)
      # X axis
      path.line_to(margin + plot_width, margin + plot_height)
    end

    # Draw area plot
    if data.size > 1
      area_brush = UIng::Area::Draw::Brush.new(:solid, 0.2, 0.6, 1.0, 0.3)
      line_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.4, 0.8, 1.0)

      # Fill area
      ctx.fill_path(area_brush) do |path|
        # Start from bottom left
        first_x = margin + (data.first[0].to_f - min_pos) / (max_pos - min_pos) * plot_width
        path.new_figure(first_x, margin + plot_height)

        # Draw top line
        data.each do |pos, val|
          x = margin + (pos.to_f - min_pos) / (max_pos - min_pos) * plot_width
          y = margin + plot_height - (val - min_val) / (max_val - min_val) * plot_height
          path.line_to(x, y)
        end

        # Close to bottom
        last_x = margin + (data.last[0].to_f - min_pos) / (max_pos - min_pos) * plot_width
        path.line_to(last_x, margin + plot_height)
      end

      # Draw outline
      ctx.stroke_path(line_brush, thickness: 2.0) do |path|
        first_pos, first_val = data.first
        first_x = margin + (first_pos.to_f - min_pos) / (max_pos - min_pos) * plot_width
        first_y = margin + plot_height - (first_val - min_val) / (max_val - min_val) * plot_height
        path.new_figure(first_x, first_y)

        data[1..].each do |pos, val|
          x = margin + (pos.to_f - min_pos) / (max_pos - min_pos) * plot_width
          y = margin + plot_height - (val - min_val) / (max_val - min_val) * plot_height
          path.line_to(x, y)
        end
      end
    end
  end

  def run
    @main_window.show
    UIng.main
    UIng.uninit
  end
end

# Entry point
if ARGV.size > 0
  puts "Usage: #{PROGRAM_NAME}"
  puts "This is a GUI application. Run without arguments."
  exit 1
end

UIng.init
D4PlotApp.new.run
