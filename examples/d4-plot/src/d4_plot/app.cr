require "uing"
require "../../../../src/d4"
require "./data_sampler"
require "./log"
require "./plot_renderer"
require "./region"

module D4Plot
  class App
    PROGRAM_NAME   = "D4 Plot Viewer"
    REPOSITORY_URL = "https://github.com/kojix2/d4.cr"

    @main_window : UIng::Window
    @file_button : UIng::Button
    @region_entry : UIng::Entry
    @plot_button : UIng::Button
    @area : UIng::Area
    @handler : UIng::Area::Handler
    @renderer : PlotRenderer
    @open_menu_item : UIng::MenuItem
    @about_menu_item : UIng::MenuItem
    @d4_file : D4::File?
    @current_file_path : String?
    @plot_data : Array(PlotPoint)?

    def self.create_menu_bar
      file_menu = UIng::Menu.new("File")
      open_item = file_menu.append_item("Open")
      file_menu.append_separator
      file_menu.append_quit_item

      help_menu = UIng::Menu.new("Help")
      about_item = help_menu.append_about_item

      {open: open_item, about: about_item}
    end

    def initialize(menu_items)
      @open_menu_item = menu_items[:open]
      @about_menu_item = menu_items[:about]
      @main_window = UIng::Window.new(PROGRAM_NAME, 800, 600, menubar: true)
      @file_button = UIng::Button.new("Open D4 File")
      @region_entry = UIng::Entry.new
      @plot_button = UIng::Button.new("Plot")
      @handler = UIng::Area::Handler.new
      @area = UIng::Area.new(@handler)
      @renderer = PlotRenderer.new
      @d4_file = nil
      @current_file_path = nil
      @plot_data = nil

      setup_ui
      setup_handlers
      setup_menu_handlers
    end

    def run
      @main_window.show
      UIng.main
      UIng.uninit
    end

    private def setup_ui
      vbox = UIng::Box.new(:vertical)
      vbox.padded = true

      hbox = UIng::Box.new(:horizontal)
      hbox.padded = true
      hbox.append(@file_button, false)
      hbox.append(@region_entry, true)
      hbox.append(@plot_button, false)

      @region_entry.text = "chr1:1000-2000"

      vbox.append(hbox, false)
      vbox.append(@area, true)

      @main_window.child = vbox
      @main_window.margined = true

      @main_window.on_closing do
        close_current_file
        UIng.quit
        true
      end
    end

    private def setup_handlers
      @file_button.on_clicked do
        open_file_dialog
      end

      @plot_button.on_clicked do
        plot_region
      end

      @handler.draw do |_, params|
        @renderer.draw(params, @plot_data)
      end
    end

    private def setup_menu_handlers
      @open_menu_item.on_clicked do |window|
        open_file_dialog(window)
      end

      @about_menu_item.on_clicked do |window|
        window.msg_box("About #{PROGRAM_NAME}", "#{PROGRAM_NAME}\n#{REPOSITORY_URL}")
      end

      UIng.on_should_quit do
        close_current_file
        @main_window.destroy
        true
      end
    end

    private def open_file_dialog(window : UIng::Window = @main_window)
      file_path = window.open_file
      load_d4_file(file_path) if file_path && !file_path.empty?
    end

    private def load_d4_file(file_path : String)
      close_current_file
      @d4_file = D4::File.open(file_path)
      @current_file_path = file_path

      filename = File.basename(file_path)
      @main_window.title = "#{PROGRAM_NAME} - #{filename}"

      Log.info "Loaded D4 file: #{file_path}"

      if d4 = @d4_file
        chromosomes = d4.chromosomes
        Log.info "Available chromosomes: #{chromosomes.keys.join(", ")}"
        Log.info "Sum index: #{d4.has_sum_index? ? "available" : "not available"}"
      end
    rescue ex
      Log.error "Error loading D4 file: #{ex.message}"
      @main_window.msg_box_error("Error", "Failed to load D4 file: #{ex.message}")
    end

    private def close_current_file
      @d4_file.try(&.close)
      @d4_file = nil
    end

    private def plot_region
      return unless d4 = @d4_file

      region_text = @region_entry.text
      return unless region_text

      region = Region.parse(region_text)
      unless region
        @main_window.msg_box_error("Error", "Invalid region format. Use: chr1:1000-2000")
        return
      end

      unless region.valid?
        @main_window.msg_box_error("Error", "Invalid region (must be 1-based inclusive: start >=1 and start <= end)")
        return
      end

      Log.info "Plotting region (user 1-based): #{region.chromosome}:#{region.start1}-#{region.end1} -> internal 0-based half-open: #{region.start0}-#{region.end0_exclusive}"
      Log.info "Sampling mode: #{d4.has_sum_index? ? "sum index with streaming fallback" : "streaming values"}"

      @plot_data = DataSampler.downsample(d4, region)
      @area.queue_redraw_all
    end
  end
end
