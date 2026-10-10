require "uing"
require "./annotation_renderer"
require "./plot_settings"
require "./plot_geometry"
require "./view"

module D4Plot
  class PlotRenderer
    property hover_index : Int32? = nil
    property selection : Tuple(Float64, Float64)? = nil

    def initialize
      @annotation_renderer = AnnotationRenderer.new
    end

    def geometry(width, height, annotation_track : AnnotationTrack?) : PlotGeometry
      PlotGeometry.new(width, height, AnnotationRenderer.height_for(annotation_track))
    end

    def draw(params, view : SampledView?, settings : PlotSettings, chromosomes : Hash(String, UInt32), annotation_track : AnnotationTrack?, loading : Bool)
      ctx = params.context
      width, height = params.area_width, params.area_height
      ctx.fill_path(brush(1.0, 1.0, 1.0)) { |path| path.add_rectangle(0, 0, width, height) }
      unless view
        title = loading ? "Loading signal…" : "Open a D4 file to explore genomic signal"
        label(ctx, title, 20.0, height / 2 - 40, width - 40, :center, 17.0)
        label(ctx, "Choose a chromosome, then enter a region or use the zoom controls.", 20.0, height / 2, width - 40, :center)
        return
      end
      layout = geometry(width, height, annotation_track)
      region = view.region
      label(ctx, "#{region.chromosome}:#{DisplayFormat.position(region.start1)}–#{DisplayFormat.position(region.end1)}  |  #{DisplayFormat.position(region.length)} bp", layout.left, 8.0, layout.width, :left, 13.0)
      draw_overview(ctx, layout, region, chromosomes)
      range = settings.y_range(view.points.min_of(&.[1]), view.points.max_of(&.[1]))
      label(ctx, "Mean signal", layout.left, layout.top - 22, 160.0)
      scale = settings.y_min ? "Fixed Y scale" : "Auto Y scale"
      label(ctx, "#{view.resolution}  |  #{scale}", layout.left + 160, layout.top - 22, Math.max(layout.width - 160, 1.0), :right)
      draw_grid(ctx, layout, range)
      ctx.save
      ctx.clip_path { |path| path.add_rectangle(layout.left, layout.top, layout.width, layout.height) }
      draw_bins(ctx, view, layout, range, settings)
      draw_reference_lines(ctx, layout, range, settings)
      draw_inspection(ctx, view, layout)
      ctx.restore
      draw_ticks(ctx, layout, region)
      annotation_height = AnnotationRenderer.height_for(annotation_track)
      @annotation_renderer.draw(ctx, annotation_track, region, layout.left, layout.annotation_top, layout.width, annotation_height)
      if loading
        label(ctx, "Loading requested region… previous view shown", layout.left, layout.top + 8, layout.width, :center)
      end
    end

    private def draw_overview(ctx, layout, region, chromosomes)
      return unless size = chromosomes[region.chromosome]?
      return if size == 0
      y = 38.0
      ctx.fill_path(brush(0.89, 0.91, 0.94)) { |path| path.add_rectangle(layout.left, y, layout.width, 14) }
      x = layout.left + region.start0.to_f / size * layout.width
      width = Math.max(region.length.to_f / size * layout.width, 2.0)
      x = Math.min(x, layout.left + layout.width - width)
      ctx.fill_path(brush(0.12, 0.4, 0.68, 0.8)) { |path| path.add_rectangle(x, y - 2, width, 18) }
      label(ctx, "1", layout.left, y + 18, 80.0)
      label(ctx, "#{DisplayFormat.position(size)} bp", layout.left + layout.width - 130, y + 18, 130.0, :right)
    end

    private def draw_grid(ctx, layout, range)
      low, high = range
      5.times do |index|
        value = low + (high - low) * index / 4
        y = y_for(value, layout, range)
        ctx.stroke_path(brush(0.88, 0.9, 0.92), thickness: 1.0) do |path|
          path.new_figure(layout.left, y)
          path.line_to(layout.left + layout.width, y)
        end
        label(ctx, "%.3g" % value, 2.0, y - 8, layout.left - 12, :right)
      end
    end

    private def draw_bins(ctx, view, layout, range, settings)
      red, green, blue, alpha = settings.plot_color
      baseline = y_for(0.0.clamp(range[0], range[1]), layout, range)
      ctx.fill_path(brush(red, green, blue, alpha * 0.25)) do |path|
        path.new_figure(layout.left, baseline)
        view.points.each_with_index do |point, index|
          left, right = view.bin_edges(index)
          y = y_for(point[1], layout, range)
          path.line_to(layout.x_for(left, view.region), y)
          path.line_to(layout.x_for(right, view.region), y)
        end
        path.line_to(layout.left + layout.width, baseline)
        path.close_figure
      end
      ctx.stroke_path(brush(red, green, blue, alpha), thickness: 1.5) do |path|
        path.new_figure(layout.left, y_for(view.points.first[1], layout, range))
        view.points.each_with_index do |point, index|
          left, right = view.bin_edges(index)
          y = y_for(point[1], layout, range)
          path.line_to(layout.x_for(left, view.region), y)
          path.line_to(layout.x_for(right, view.region), y)
        end
      end
    end

    private def draw_reference_lines(ctx, layout, range, settings)
      settings.h_lines.each do |value|
        next unless range[0] <= value <= range[1]
        y = y_for(value, layout, range)
        ctx.stroke_path(brush(0.75, 0.3, 0.12), thickness: 1.0) do |path|
          path.new_figure(layout.left, y)
          path.line_to(layout.left + layout.width, y)
        end
        label(ctx, DisplayFormat.value(value), layout.left + layout.width - 80, y - 18, 75.0, :right)
      end
    end

    private def draw_inspection(ctx, view, layout)
      if index = @hover_index
        if 0 <= index < view.points.size
          left, right = view.bin_edges(index)
          x = layout.x_for(left, view.region)
          width = Math.max(layout.x_for(right, view.region) - x, 1.0)
          ctx.fill_path(brush(0.2, 0.4, 0.6, 0.12)) { |path| path.add_rectangle(x, layout.top, width, layout.height) }
        end
      end
      if selection = @selection
        left, right = selection.minmax
        ctx.fill_path(brush(0.1, 0.5, 0.7, 0.2)) do |path|
          path.add_rectangle(layout.left + left * layout.width, layout.top, (right - left) * layout.width, layout.height)
        end
      end
    end

    private def draw_ticks(ctx, layout, region)
      count = Math.min(5, region.length.to_i64).to_i
      positions = Array.new(count) do |index|
        region.start1.to_i64 + (count == 1 ? 0_i64 : (region.length.to_i64 - 1) * index // (count - 1))
      end
      positions.each do |position|
        x = layout.left + (position - region.start0 - 0.5) / region.length * layout.width
        label(ctx, DisplayFormat.position(position), x - 60, layout.top + layout.height + 8, 120.0, :center)
      end
      label(ctx, "Position (1-based, inclusive)", layout.left, layout.top + layout.height + 30, layout.width, :center)
    end

    private def y_for(value, layout, range)
      layout.top + layout.height * (1.0 - (value - range[0]) / (range[1] - range[0]))
    end

    private def brush(red, green, blue, alpha = 1.0)
      UIng::Area::Draw::Brush.new(:solid, red, green, blue, alpha)
    end

    private def label(ctx, text, x, y, width, align = :left, size = 11.0)
      UIng::Area::AttributedString.open(text) do |string|
        string.set_attribute(UIng::Area::Attribute.new_color(0.18, 0.22, 0.28, 1.0), 0_u64, text.bytesize.to_u64)
        alignment = case align
                    when :center then UIng::Area::Draw::TextAlign::Center
                    when :right  then UIng::Area::Draw::TextAlign::Right
                    else              UIng::Area::Draw::TextAlign::Left
                    end
        UIng::Area::Draw::TextLayout.open(string: string, default_font: UIng::FontDescriptor.new(size: size), width: width, align: alignment) do |layout|
          ctx.draw_text_layout(layout, x, y)
        end
      end
    end
  end
end
