require "uing"
require "../../../../src/d4"
require "./data_sampler"
require "./log"
require "./plot_settings"
require "./plot_renderer"
require "./region"
require "./settings_window"

module D4Plot
  class App
    PROGRAM_NAME   = "D4 Plot Viewer"
    REPOSITORY_URL = "https://github.com/kojix2/d4.cr"
    LEFT_BUTTON    =   1
    RIGHT_BUTTON   =   3
    DRAG_THRESHOLD = 4.0
    ZOOM_FACTOR    = 1.5

    @main_window : UIng::Window
    @file_button : UIng::Button
    @chromosome_combobox : UIng::Combobox
    @region_entry : UIng::Entry
    @plot_button : UIng::Button
    @area : UIng::Area
    @handler : UIng::Area::Handler
    @renderer : PlotRenderer
    @open_menu_item : UIng::MenuItem
    @settings_menu_item : UIng::MenuItem
    @about_menu_item : UIng::MenuItem
    @settings : PlotSettings
    @settings_window : SettingsWindow?
    @d4_file : D4::File?
    @current_file_path : String?
    @current_region : Region?
    @chromosomes : Hash(String, UInt32)?
    @chromosome_names : Array(String)
    @updating_chromosome_combobox : Bool
    @plot_data : Array(PlotPoint)?
    @drag_start_x : Float64?
    @drag_start_y : Float64?
    @drag_start_region : Region?

    def self.create_menu_bar
      file_menu = UIng::Menu.new("File")
      open_item = file_menu.append_item("Open")
      settings_item = file_menu.append_preferences_item
      file_menu.append_separator
      file_menu.append_quit_item

      help_menu = UIng::Menu.new("Help")
      about_item = help_menu.append_about_item

      {open: open_item, settings: settings_item, about: about_item}
    end

    def initialize(menu_items)
      @open_menu_item = menu_items[:open]
      @settings_menu_item = menu_items[:settings]
      @about_menu_item = menu_items[:about]
      @main_window = UIng::Window.new(PROGRAM_NAME, 800, 600, menubar: true)
      @file_button = UIng::Button.new("Open D4 File")
      @chromosome_combobox = UIng::Combobox.new
      @region_entry = UIng::Entry.new
      @plot_button = UIng::Button.new("Plot")
      @handler = UIng::Area::Handler.new
      @area = UIng::Area.new(@handler)
      @renderer = PlotRenderer.new
      @settings = PlotSettings.new
      @settings_window = nil
      @d4_file = nil
      @current_file_path = nil
      @current_region = nil
      @chromosomes = nil
      @chromosome_names = [] of String
      @updating_chromosome_combobox = false
      @plot_data = nil
      @drag_start_x = nil
      @drag_start_y = nil
      @drag_start_region = nil

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
      hbox.append(@chromosome_combobox, false)
      hbox.append(@region_entry, true)
      hbox.append(@plot_button, false)

      @region_entry.text = "chr1:1000-2000"

      vbox.append(hbox, false)
      vbox.append(@area, true)

      @main_window.child = vbox
      @main_window.margined = true

      @main_window.on_closing do
        close_settings_window
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

      @chromosome_combobox.on_selected do |index|
        select_chromosome(index)
      end

      @handler.draw do |_, params|
        @renderer.draw(
          params,
          @plot_data,
          @settings,
          @current_region,
          @chromosomes
        )
      end

      @handler.key_event do |_, event|
        if enter_key?(event)
          plot_region
          true
        else
          false
        end
      end

      @handler.mouse_event do |_, event|
        handle_mouse_event(event)
      end
    end

    private def setup_menu_handlers
      @open_menu_item.on_clicked do |window|
        open_file_dialog(window)
      end

      @settings_menu_item.on_clicked do
        open_settings_window
      end

      @about_menu_item.on_clicked do |window|
        window.msg_box("About #{PROGRAM_NAME}", "#{PROGRAM_NAME}\n#{REPOSITORY_URL}")
      end

      UIng.on_should_quit do
        close_settings_window
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
        @chromosomes = d4.chromosomes
        if chromosomes = @chromosomes
          update_chromosome_combobox(chromosomes)
          Log.info "Available chromosomes: #{chromosomes.keys.join(", ")}"
        end
        Log.info "Sum index: #{d4.has_sum_index? ? "available" : "not available"}"
      end
    rescue ex
      Log.error "Error loading D4 file: #{ex.message}"
      @main_window.msg_box_error("Error", "Failed to load D4 file: #{ex.message}")
    end

    private def close_current_file
      @d4_file.try(&.close)
      @d4_file = nil
      @chromosomes = nil
      @chromosome_names.clear
      @chromosome_combobox.clear
      @current_region = nil
      @plot_data = nil
    end

    private def close_settings_window
      @settings_window.try(&.destroy)
      @settings_window = nil
    end

    private def open_settings_window
      if window = @settings_window
        window.show
        return
      end

      settings_window = SettingsWindow.new(
        @settings,
        @main_window,
        -> { settings_applied },
        -> { @settings_window = nil }
      )
      @settings_window = settings_window
      settings_window.show
    end

    private def settings_applied
      Log.info "Plot settings: point_count=#{@settings.point_count}, use_sum_index=#{@settings.use_sum_index?}, show_axis_ticks=#{@settings.show_axis_ticks?}, y_axis_from_zero=#{@settings.y_axis_from_zero?}"

      if @plot_data && @d4_file
        plot_region
      else
        @area.queue_redraw_all
      end
    end

    private def plot_region
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

      plot_region(region, sync_chromosome: true)
    end

    private def plot_region(region : Region)
      @region_entry.text = "#{region.chromosome}:#{region.start1}-#{region.end1}"
      plot_region(region, sync_chromosome: false)
    end

    private def plot_region(region : Region, sync_chromosome : Bool)
      return unless d4 = @d4_file

      Log.info "Plotting region (user 1-based): #{region.chromosome}:#{region.start1}-#{region.end1} -> internal 0-based half-open: #{region.start0}-#{region.end0_exclusive}"
      Log.info "Sampling mode: #{sampling_mode(d4)}"

      sync_chromosome_selection(region.chromosome) if sync_chromosome
      @current_region = region
      @plot_data = DataSampler.downsample(d4, region, @settings.point_count, @settings.use_sum_index?)
      @area.queue_redraw_all
    end

    private def update_chromosome_combobox(chromosomes)
      @updating_chromosome_combobox = true
      @chromosome_combobox.clear
      @chromosome_names = chromosomes.keys.to_a

      @chromosome_names.each do |name|
        @chromosome_combobox.append(name)
      end

      return if @chromosome_names.empty?

      first_name = @chromosome_names.first
      @chromosome_combobox.selected = 0
      set_default_region(first_name)
    ensure
      @updating_chromosome_combobox = false
    end

    private def select_chromosome(index)
      return if @updating_chromosome_combobox
      return if index < 0 || index >= @chromosome_names.size

      chromosome = @chromosome_names[index]
      if current = @current_region
        return if current.chromosome == chromosome
      end

      set_default_region(chromosome)
    end

    private def set_default_region(chromosome)
      return unless chromosomes = @chromosomes
      chrom_size = chromosomes[chromosome]?
      return unless chrom_size

      plot_region(Region.new(chromosome, 1_u32, chrom_size))
    end

    private def sync_chromosome_selection(chromosome)
      if index = @chromosome_names.index(chromosome)
        return if @chromosome_combobox.selected == index

        @updating_chromosome_combobox = true
        @chromosome_combobox.selected = index
      end
    ensure
      @updating_chromosome_combobox = false
    end

    private def handle_mouse_event(event)
      if event.down == LEFT_BUTTON
        handle_left_button_down(event)
      elsif event.up == LEFT_BUTTON
        finish_left_button(event)
      elsif event.up == RIGHT_BUTTON
        zoom_region(event, 1.0 / ZOOM_FACTOR)
      end
    end

    private def handle_left_button_down(event)
      if move_region_to_overview_position(event)
        clear_drag
      else
        start_drag(event)
      end
    end

    private def start_drag(event)
      return unless region = @current_region

      @drag_start_x = event.x
      @drag_start_y = event.y
      @drag_start_region = region
    end

    private def finish_left_button(event)
      start_x = @drag_start_x
      start_y = @drag_start_y
      start_region = @drag_start_region
      clear_drag
      return unless start_x && start_y && start_region

      dx = event.x - start_x
      dy = event.y - start_y
      if Math.sqrt(dx * dx + dy * dy) >= DRAG_THRESHOLD
        pan_region(start_region, dx, event.area_width, event.area_height)
      else
        zoom_region(event, ZOOM_FACTOR)
      end
    end

    private def clear_drag
      @drag_start_x = nil
      @drag_start_y = nil
      @drag_start_region = nil
    end

    private def move_region_to_overview_position(event)
      return false unless region = @current_region
      return false unless fraction = @renderer.overview_fraction(event.x, event.y, event.area_width, event.area_height, @settings, region, @chromosomes)
      return false unless chromosomes = @chromosomes
      chrom_size = chromosomes[region.chromosome]?
      return false unless chrom_size

      region_len = region_length(region)
      center0 = (fraction * chrom_size).round.to_i64
      apply_region0(region.chromosome, center0 - region_len.to_i64 // 2, region_len)
      true
    end

    private def zoom_region(event, factor)
      return unless region = @current_region
      return unless fraction = @renderer.plot_fraction(event.x, event.area_width, event.area_height, @settings)

      region_len = region_length(region)
      new_len = (region_len / factor).round.to_u32
      new_len = 1_u32 if new_len < 1_u32
      anchor0 = region.start0.to_f + region_len * fraction
      new_start0 = (anchor0 - new_len * fraction).round.to_i64
      apply_region0(region.chromosome, new_start0, new_len)
    end

    private def pan_region(region, dx, area_width, area_height)
      return unless plot_width = @renderer.plot_width(area_width, area_height, @settings)
      return if plot_width <= 0

      region_len = region_length(region)
      delta = (-dx / plot_width * region_len).round.to_i64
      apply_region0(region.chromosome, region.start0.to_i64 + delta, region_len.to_u32)
    end

    private def apply_region0(chromosome, start0, length)
      return unless chromosomes = @chromosomes
      chrom_size = chromosomes[chromosome]?
      return unless chrom_size

      length = chrom_size if length > chrom_size
      max_start0 = chrom_size - length
      clamped_start0 = start0.clamp(0_i64, max_start0.to_i64).to_u32
      new_region = Region.new(chromosome, clamped_start0 + 1_u32, clamped_start0 + length)
      plot_region(new_region)
    end

    private def region_length(region)
      region.end0_exclusive - region.start0
    end

    private def enter_key?(event)
      return false if event.up != 0

      event.ext_key.n_enter? || event.key == '\r' || event.key == '\n'
    end

    private def sampling_mode(d4)
      if @settings.use_sum_index? && d4.has_sum_index?
        "sum index with streaming fallback"
      elsif @settings.use_sum_index?
        "streaming values (sum index unavailable)"
      else
        "streaming values"
      end
    end
  end
end
