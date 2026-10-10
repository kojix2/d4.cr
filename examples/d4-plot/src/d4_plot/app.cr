require "uing"
require "d4"
require "./view_loader"
require "./plot_renderer"
require "./settings_window"
require "./log"
require "./toolbar"

module D4Plot
  class App
    PROGRAM_NAME = "D4 Plot Viewer"
    @window : UIng::Window
    @area : UIng::Area
    @handler = UIng::Area::Handler.new
    @renderer = PlotRenderer.new
    @settings = PlotSettings.new
    @settings_window : SettingsWindow?
    @loader = ViewLoader.new
    @history = ViewHistory.new
    @path : String?
    @track_name = ""
    @tracks = {} of String => Hash(String, UInt32)
    @denominators = {} of String => Float64
    @track_names = [] of String
    @chromosomes = {} of String => UInt32
    @chromosome_names = [] of String
    @view : SampledView?
    @annotation : AnnotationTrack?
    @annotation_path : String?
    @request_id = 0
    @requested_region : Region?
    @history_move = 0
    @updating = false
    @loading = false
    @closed = false
    @drag : Tuple(Float64, Region, Bool)?
    @file_label = UIng::Label.new("No D4 file open")
    @track_combo = UIng::Combobox.new
    @chromosome_combo = UIng::Combobox.new
    @region_entry = UIng::Entry.new
    @go = UIng::Button.new("Go")
    @tools = Toolbar.new
    @annotation_label = UIng::Label.new("No annotations — use GFF3, GTF or BED from the same assembly.")
    @remove_annotation = UIng::Button.new("Remove")
    @status = UIng::Label.new("Open a D4 file to begin. Coordinates are 1-based, inclusive.")
    @inspection = UIng::Label.new("Move the pointer over the signal to inspect a bin.")

    def self.create_menu_bar
      file = UIng::Menu.new("File")
      open = file.append_item("Open D4…")
      export = file.append_item("Export displayed bins…")
      settings = file.append_preferences_item
      file.append_quit_item
      help = UIng::Menu.new("Help")
      guide = help.append_item("Navigation and data interpretation")
      about = help.append_about_item
      {open: open, export: export, settings: settings, guide: guide, about: about}
    end

    def initialize(menu_items)
      @window = UIng::Window.new(PROGRAM_NAME, 1120, 780, menubar: true, margined: true)
      @area = UIng::Area.new(@handler)
      setup_ui
      setup_handlers
      menu_items[:open].on_clicked { open_file_dialog }
      menu_items[:export].on_clicked { export_view }
      menu_items[:settings].on_clicked { open_settings }
      menu_items[:guide].on_clicked { show_help }
      menu_items[:about].on_clicked { @window.msg_box(PROGRAM_NAME, "D4 genomic signal viewer\nhttps://github.com/kojix2/d4.cr") }
      @window.on_closing { shutdown; UIng.quit; true }
      UIng.on_should_quit { shutdown; @window.destroy; true }
      UIng.timer(30) do
        if @closed
          0
        else
          receive_result
          1
        end
      end
      update_controls
    end

    def run(path : String? = nil, region : String? = nil)
      @window.show
      load_d4_file(path, region) if path
      # Advance both event loops: tabix pipe readers and child-process
      # notifications need Crystal's scheduler as well as the native UI loop.
      UIng.main_steps
      while UIng.main_step(false)
        sleep 8.milliseconds
      end
    ensure
      shutdown
      @loader.wait
      UIng.uninit
    end

    private def row : UIng::Box
      box = UIng::Box.new(:horizontal)
      box.padded = true
      box
    end

    private def setup_ui
      root = UIng::Box.new(:vertical)
      root.padded = true
      files = row
      files.append(@file_label, true)
      files.append(UIng::Label.new("Track"), false)
      files.append(@track_combo, false)
      root.append(files, false)

      location = row
      location.append(UIng::Label.new("Chromosome"), false)
      location.append(@chromosome_combo, false)
      location.append(UIng::Label.new("Region (1-based)"), false)
      location.append(@region_entry, true)
      location.append(@go, false)
      root.append(location, false)

      annotations = row
      annotations.append(@annotation_label, true)
      annotations.append(@remove_annotation, false)
      root.append(annotations, false)
      root.append(@area, true)
      root.append(@inspection, false)
      root.append(@status, false)
      root.append(UIng::Label.new("Drag: pan   |   Shift+drag: select range   |   Double-click: zoom   |   Plot keys: ← → + − Home   |   Esc: cancel"), false)
      @window.toolbar = @tools.native
      @window.child = root
    end

    private def setup_handlers
      @tools.open.on_clicked { open_file_dialog }
      @tools.annotations.on_clicked { open_annotation_dialog }
      @tools.settings.on_clicked { open_settings }
      @go.on_clicked { go_to_entry }
      @chromosome_combo.on_selected { |index| select_chromosome(index) unless @updating }
      @track_combo.on_selected { |index| select_track(index) unless @updating }
      @tools.zoom_in.on_clicked { zoom(2.0) }
      @tools.zoom_out.on_clicked { zoom(0.5) }
      @tools.left.on_clicked { move(-0.5) }
      @tools.right.on_clicked { move(0.5) }
      @tools.whole.on_clicked { whole_chromosome }
      @tools.back.on_clicked { history_back }
      @tools.forward.on_clicked { history_forward }
      @tools.cancel.on_clicked { cancel_loading }
      @tools.export.on_clicked { export_view }
      @remove_annotation.on_clicked do
        @annotation_path = nil
        @annotation = nil
        @annotation_label.text = "No annotations — use GFF3, GTF or BED from the same assembly."
        refresh
      end
      @handler.draw { |_, params| @renderer.draw(params, @view, @settings, @chromosomes, @annotation, @loading) }
      @handler.mouse_event { |_, event| mouse_event(event) }
      @handler.mouse_crossed do |_, left|
        if left
          @renderer.hover_index = nil
          @area.queue_redraw_all
        end
      end
      @handler.drag_broken { clear_drag }
      @handler.key_event { |_, event| key_event(event) }
    end

    private def open_file_dialog
      if path = @window.open_file
        load_d4_file(path)
      end
    end

    private def load_d4_file(path : String, region_text : String? = nil)
      tracks = {} of String => Hash(String, UInt32)
      denominators = {} of String => Float64
      D4.open(path) do |file|
        file.each_track do |track|
          tracks[track.name] = track.chromosomes.reject { |chromosome| chromosome.size == 0 }.to_h { |chromosome| {chromosome.name, chromosome.size.to_u32} }
          denominators[track.name] = track.metadata.denominator
        end
      end
      raise "This D4 file has no non-empty chromosomes." if tracks.values.all?(&.empty?)
      cancel_loading
      @path = path
      @view = nil
      @tracks = tracks
      @denominators = denominators
      @track_names = tracks.keys
      @file_label.text = File.basename(path)
      @window.title = "#{PROGRAM_NAME} — #{File.basename(path)}"
      @annotation = nil
      @annotation_path = nil
      @annotation_label.text = "Assembly not recorded in D4 — choose annotations from the matching assembly."
      @updating = true
      @track_combo.clear
      @track_names.each { |name| @track_combo.append(name.empty? ? "Default" : name) }
      index = @track_names.index { |name| !tracks[name].empty? } || 0
      @track_combo.selected = index
      @updating = false
      select_track(index, region_text)
    rescue ex
      @updating = false
      show_error("Could not open D4 file", ex)
    end

    private def select_track(index : Int32, region_text : String? = nil)
      return unless name = @track_names[index]?
      previous = active_region
      cancel_loading
      @track_name = name
      @chromosomes = @tracks[name]
      @chromosome_names = @chromosomes.keys
      @view = nil
      @annotation = nil
      @history.clear
      @updating = true
      @chromosome_combo.clear
      @chromosome_names.each { |chromosome| @chromosome_combo.append(chromosome) }
      @chromosome_combo.selected = @chromosome_names.empty? ? nil : 0
      @updating = false
      @area.queue_redraw_all
      if @chromosome_names.empty?
        @status.text = "This track has no non-empty chromosomes. Select another track."
        update_controls
      elsif region_text
        @region_entry.text = region_text
        go_to_entry
      elsif previous && @chromosomes[previous.chromosome]?.try { |size| previous.end1 <= size }
        request_view(previous)
      else
        select_chromosome(0)
      end
    end

    private def select_chromosome(index : Int32)
      return unless name = @chromosome_names[index]?
      request_view(Region.new(name, 1_u32, @chromosomes[name]))
    end

    private def go_to_entry
      request_view(Region.resolve(@region_entry.text || "", @chromosomes))
    rescue ex
      show_error("Check region", ex)
    end

    private def request_view(region : Region, history_move : Int32 = 0)
      return unless path = @path
      region.validate!(@chromosomes)
      rollback_history
      @history_move = history_move
      @requested_region = region
      @region_entry.text = region.to_s
      @updating = true
      @chromosome_combo.selected = @chromosome_names.index(region.chromosome)
      @updating = false
      clear_drag
      @renderer.hover_index = nil
      @loading = true
      @status.text = "Loading #{region}…"
      @inspection.text = "Loading requested region; the plot retains the previous completed view."
      @request_id = @loader.submit(path, @track_name, region, @settings.point_count, @settings.use_sum_index?, @annotation_path, @settings.annotation_feature_limit)
      update_controls
      @area.queue_redraw_all
    end

    private def receive_result
      return unless result = @loader.poll
      return unless result.request.id == @request_id && @loading
      @loading = false
      @requested_region = nil
      if error = result.error
        rollback_history
        @status.text = "Read failed: #{error}"
        restore_location
      elsif view = result.view
        @view = view
        @annotation = result.annotation_track
        @history.record(view.region) if @history_move == 0
        @history_move = 0
        @region_entry.text = view.region.to_s
        denominator = @denominators[@track_name]
        scaling = denominator == 1 ? "" : " | D4 scale: ÷#{DisplayFormat.value(denominator)}"
        @status.text = "#{DisplayFormat.position(view.region.length)} bp | #{view.points.size} bins | Region mean: #{DisplayFormat.value(view.mean)} | #{result.elapsed_ms.round(1)} ms#{scaling}"
        @inspection.text = "#{view.resolution}. Hover to inspect; zoom in to resolve peaks within a bin."
      end
      update_controls
      @area.queue_redraw_all
    end

    private def active_region : Region?
      @requested_region || @view.try(&.region)
    end

    private def zoom(factor : Float64, fraction : Float64 = 0.5)
      return unless region = active_region
      length = Math.max((region.length / factor).round.to_i64, 1_i64)
      left = (region.start0 + region.length * fraction - length * fraction).round.to_i64
      request_view(Region.bounded(region.chromosome, left, length, @chromosomes[region.chromosome]))
    end

    private def move(fraction : Float64)
      return unless region = active_region
      delta = (region.length * fraction).round.to_i64
      delta = fraction < 0 ? -1_i64 : 1_i64 if delta == 0
      request_view(Region.bounded(region.chromosome, region.start0.to_i64 + delta, region.length.to_i64, @chromosomes[region.chromosome]))
    end

    private def whole_chromosome
      return unless region = active_region
      request_view(Region.new(region.chromosome, 1_u32, @chromosomes[region.chromosome]))
    end

    private def history_back
      return if @loading
      if region = @history.back
        request_view(region, -1)
      end
    end

    private def history_forward
      return if @loading
      if region = @history.forward
        request_view(region, 1)
      end
    end

    private def rollback_history
      @history.forward if @history_move == -1
      @history.back if @history_move == 1
      @history_move = 0
    end

    private def cancel_loading
      @loader.cancel
      @loading = false
      @requested_region = nil
      rollback_history
      restore_location
      @status.text = "Loading cancelled; previous view retained."
      update_controls
      @area.queue_redraw_all
    end

    private def restore_location
      if view = @view
        @region_entry.text = view.region.to_s
        @inspection.text = "#{view.resolution}. Hover to inspect a bin."
        @updating = true
        @chromosome_combo.selected = @chromosome_names.index(view.region.chromosome)
        @updating = false
      end
    end

    private def open_annotation_dialog
      return unless @path
      if path = @window.open_file
        @annotation_path = path
        @annotation_label.text = "#{File.basename(path)} | chromosome names must match; verify the reference assembly."
        refresh
      end
    end

    private def refresh
      if region = active_region
        request_view(region)
      else
        update_controls
        @area.queue_redraw_all
      end
    end

    private def open_settings
      if window = @settings_window
        window.show
      else
        window = SettingsWindow.new(@settings, @window, -> { refresh }, -> { @settings_window = nil })
        @settings_window = window
        window.show
      end
    end

    private def export_view
      return unless view = @view
      return if @loading
      if path = @window.save_file
        [@path, @annotation_path].compact.each do |source|
          if File.expand_path(path) == File.expand_path(source) || (File.exists?(path) && File.same?(path, source))
            raise "Choose a different path from the input D4 or annotation file."
          end
        end
        File.open(path, "w") do |io|
          io << "# Source: " << (@path || "").gsub(/[\r\n]/, " ") << "; track: " << @track_name.gsub(/[\r\n]/, " ") << '\n'
          view.write_bedgraph(io)
        end
        @status.text = "Exported #{view.points.size} bin means to #{File.basename(path)} (bedGraph, 0-based half-open)."
      end
    rescue ex
      show_error("Could not export bins", ex)
    end

    private def update_controls
      ready = !@path.nil? && !@chromosomes.empty?
      ready ? @go.enable : @go.disable
      [@tools.annotations, @tools.left, @tools.right, @tools.zoom_in, @tools.zoom_out, @tools.whole].each do |control|
        ready ? control.enable : control.disable
      end
      ready ? @chromosome_combo.enable : @chromosome_combo.disable
      ready ? @region_entry.enable : @region_entry.disable
      @track_names.size > 1 ? @track_combo.enable : @track_combo.disable
      @loading ? @tools.cancel.enable : @tools.cancel.disable
      @view && !@loading ? @tools.export.enable : @tools.export.disable
      update_history_controls
      @annotation_path ? @remove_annotation.enable : @remove_annotation.disable
    end

    private def update_history_controls
      @history.back? && !@loading ? @tools.back.enable : @tools.back.disable
      @history.forward? && !@loading ? @tools.forward.enable : @tools.forward.disable
    end

    private def mouse_event(event)
      return unless view = @view
      return if @loading
      layout = @renderer.geometry(event.area_width, event.area_height, @annotation)
      fraction = layout.fraction(event.x)
      inside = layout.contains?(event.x, event.y)
      if inside
        index = view.bin_at(fraction)
        @inspection.text = view.inspect_bin(index)
        @renderer.hover_index = index
      else
        @renderer.hover_index = nil
      end
      if event.down == 1
        start_mouse_action(event, view.region, layout, fraction, inside)
      elsif event.up == 1
        finish_drag(fraction, layout)
      elsif event.up == 3 && inside
        zoom(0.5, fraction)
      elsif drag = @drag
        @renderer.selection = {drag[0], fraction} if drag[2]
      end
      @area.queue_redraw_all
    end

    private def start_mouse_action(event, region, layout, fraction, inside)
      if event.y >= 34 && event.y <= 56 && event.x >= layout.left && event.x <= layout.left + layout.width
        size = @chromosomes[region.chromosome]
        left = (fraction * size - region.length / 2).round.to_i64
        request_view(Region.bounded(region.chromosome, left, region.length.to_i64, size))
      elsif inside
        if event.count == 2
          zoom(2.0, fraction)
        else
          @drag = {fraction, region, event.modifiers.shift?}
        end
      end
    end

    private def finish_drag(fraction, layout)
      drag = @drag
      clear_drag
      return unless drag
      start, region, selecting = drag
      return if (fraction - start).abs * layout.width < 4
      if selecting
        left, right = {start, fraction}.minmax
        start0 = region.start0.to_i64 + (left * region.length).floor.to_i64
        end0 = region.start0.to_i64 + (right * region.length).ceil.to_i64
        request_view(Region.bounded(region.chromosome, start0, end0 - start0, @chromosomes[region.chromosome]))
      else
        left = region.start0.to_i64 + ((start - fraction) * region.length).round.to_i64
        request_view(Region.bounded(region.chromosome, left, region.length.to_i64, @chromosomes[region.chromosome]))
      end
    end

    private def clear_drag
      @drag = nil
      @renderer.selection = nil
    end

    private def key_event(event) : Bool
      return false if event.up?
      case event.ext_key
      when UIng::Area::ExtKey::Left   then move(-0.5)
      when UIng::Area::ExtKey::Right  then move(0.5)
      when UIng::Area::ExtKey::Home   then whole_chromosome
      when UIng::Area::ExtKey::Escape then cancel_loading
      else
        case event.key
        when '+', '='   then zoom(2.0)
        when '-'        then zoom(0.5)
        when '\r', '\n' then go_to_entry
        else                 return false
        end
      end
      true
    end

    private def show_help
      @window.msg_box("Using D4 Plot", "Open a D4 file and select its track and chromosome.\nEnter chr:start-end, chr:position, or a chromosome name, then click Go. Commas in coordinates are accepted.\n\nCoordinates in the viewer are 1-based and inclusive. The signal shows the mean in each bin, with the D4 denominator applied. Zoom in to resolve narrow peaks; a flat bin can contain variation.\n\nDrag to pan; Shift+drag to select a range; double-click to zoom in; right-click to zoom out. Click the chromosome overview to jump. Back and Forward restore visited regions. Keyboard navigation works when the plot has focus.\n\nDisplay settings control resolution and Y scale. Use a fixed Y scale when comparing regions. D4 does not identify the reference assembly here: annotations must use the same assembly and exact chromosome names.\n\nExport bins writes the displayed means as bedGraph (0-based, half-open), not the original per-base signal.")
    end

    private def show_error(title, error)
      message = error.message || error.class.name
      @status.text = message
      @window.msg_box_error(title, message)
    end

    private def shutdown
      return if @closed
      @closed = true
      @settings_window.try(&.destroy)
      @settings_window = nil
      @loader.close
      @window.toolbar = nil
      @tools.free
    end
  end
end
