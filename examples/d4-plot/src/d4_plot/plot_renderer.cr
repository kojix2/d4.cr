require "uing"
require "./data_sampler"
require "./plot_settings"
require "./region"

module D4Plot
  class PlotRenderer
    DEFAULT_MARGIN  = 50.0
    MIN_MARGIN      = 12.0
    LABEL_MARGIN    = 58.0
    TICK_COUNT      =    5
    TICK_SIZE       =  5.0
    OVERVIEW_HEIGHT = 24.0
    OVERVIEW_GAP    = 16.0
    LABEL_FONT      = UIng::FontDescriptor.new(size: 11)

    def draw(
      params : UIng::Area::Draw::Params,
      data : Array(PlotPoint)?,
      settings : PlotSettings,
      region : Region? = nil,
      chromosomes : Hash(String, UInt32)? = nil,
    )
      ctx = params.context
      width = params.area_width
      height = params.area_height
      margin = margin_for(width, height, settings.show_axis_ticks?)

      clear(ctx, width, height)
      overview_height = draw_overview(ctx, margin, width, region, chromosomes)

      if points = data
        draw_plot(ctx, points, margin, width, height, overview_height, settings) unless points.empty?
      end
    end

    def plot_fraction(x, area_width, area_height, settings : PlotSettings) : Float64?
      margin = margin_for(area_width, area_height, settings.show_axis_ticks?)
      width = area_width - 2 * margin
      return nil if width <= 0

      ((x - margin) / width).clamp(0.0, 1.0)
    end

    def plot_width(area_width, area_height, settings : PlotSettings) : Float64?
      margin = margin_for(area_width, area_height, settings.show_axis_ticks?)
      width = area_width - 2 * margin
      return nil if width <= 0

      width
    end

    def overview_fraction(x, y, area_width, area_height, settings : PlotSettings, region : Region?, chromosomes : Hash(String, UInt32)?) : Float64?
      return nil if region.nil? || chromosomes.nil? || chromosomes.empty?

      margin = margin_for(area_width, area_height, settings.show_axis_ticks?)
      overview_width = area_width - 2 * margin
      return nil if overview_width <= 0

      overview_top = margin + 3.0
      overview_bottom = margin + OVERVIEW_HEIGHT - 3.0
      return nil if y < overview_top || y > overview_bottom

      ((x - margin) / overview_width).clamp(0.0, 1.0)
    end

    private def clear(ctx, width, height)
      bg_brush = UIng::Area::Draw::Brush.new(:solid, 1.0, 1.0, 1.0, 1.0)
      ctx.fill_path(bg_brush) do |path|
        path.add_rectangle(0, 0, width, height)
      end
    end

    private def draw_overview(ctx, margin, width, region, chromosomes)
      return 0.0 if region.nil? || chromosomes.nil? || chromosomes.empty?

      draw_genome_overview(ctx, margin, margin, width - 2 * margin, OVERVIEW_HEIGHT, region, chromosomes)
      OVERVIEW_HEIGHT
    end

    private def draw_plot(ctx, points, margin, width, height, overview_height, settings)
      overview_gap = overview_height > 0 ? OVERVIEW_GAP : 0.0
      plot_left = margin
      plot_top = margin + overview_height + overview_gap
      plot_width = width - 2 * margin
      plot_height = height - plot_top - margin
      return if plot_width <= 0 || plot_height <= 0

      min_pos = points.first[0].to_f
      max_pos = points.last[0].to_f
      min_val, max_val = y_range(points.min_of(&.[1]), points.max_of(&.[1]), settings.y_axis_from_zero?)

      draw_axes(ctx, plot_left, plot_top, plot_width, plot_height)
      draw_ticks(ctx, plot_left, plot_top, min_pos, max_pos, min_val, max_val, plot_width, plot_height) if settings.show_axis_ticks?
      draw_area(ctx, points, plot_left, plot_top, min_pos, max_pos, min_val, max_val, plot_width, plot_height, settings.plot_color)
    end

    private def draw_axes(ctx, plot_left, plot_top, plot_width, plot_height)
      axis_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.0, 0.0, 1.0)
      ctx.stroke_path(axis_brush, thickness: 1.0) do |path|
        path.new_figure(plot_left, plot_top)
        path.line_to(plot_left, plot_top + plot_height)
        path.line_to(plot_left + plot_width, plot_top + plot_height)
      end
    end

    private def draw_ticks(ctx, plot_left, plot_top, min_pos, max_pos, min_val, max_val, plot_width, plot_height)
      tick_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.0, 0.0, 1.0)

      tick_values(min_pos, max_pos).each do |pos|
        x = x_for(pos, plot_left, min_pos, max_pos, plot_width)
        y = plot_top + plot_height

        ctx.stroke_path(tick_brush, thickness: 1.0) do |path|
          path.new_figure(x, y)
          path.line_to(x, y + TICK_SIZE)
        end

        draw_label(ctx, format_position(pos), x - 36.0, y + 8.0, 72.0, UIng::Area::Draw::TextAlign::Center)
      end

      tick_values(min_val, max_val).each do |value|
        x = plot_left
        y = y_for(value, plot_top, min_val, max_val, plot_height)

        ctx.stroke_path(tick_brush, thickness: 1.0) do |path|
          path.new_figure(x - TICK_SIZE, y)
          path.line_to(x, y)
        end

        draw_label(ctx, format_value(value), 2.0, y - 7.0, plot_left - 10.0, UIng::Area::Draw::TextAlign::Right)
      end
    end

    private def draw_area(ctx, points, plot_left, plot_top, min_pos, max_pos, min_val, max_val, plot_width, plot_height, plot_color)
      return unless points.size > 1

      red, green, blue, alpha = plot_color
      area_brush = UIng::Area::Draw::Brush.new(:solid, red, green, blue, alpha * 0.3)
      line_brush = UIng::Area::Draw::Brush.new(:solid, red, green, blue, alpha)

      ctx.fill_path(area_brush) do |path|
        first_x = x_for(points.first[0], plot_left, min_pos, max_pos, plot_width)
        path.new_figure(first_x, plot_top + plot_height)

        points.each do |pos, val|
          path.line_to(
            x_for(pos, plot_left, min_pos, max_pos, plot_width),
            y_for(val, plot_top, min_val, max_val, plot_height)
          )
        end

        last_x = x_for(points.last[0], plot_left, min_pos, max_pos, plot_width)
        path.line_to(last_x, plot_top + plot_height)
      end

      ctx.stroke_path(line_brush, thickness: 2.0) do |path|
        first_pos, first_val = points.first
        path.new_figure(
          x_for(first_pos, plot_left, min_pos, max_pos, plot_width),
          y_for(first_val, plot_top, min_val, max_val, plot_height)
        )

        points[1..].each do |pos, val|
          path.line_to(
            x_for(pos, plot_left, min_pos, max_pos, plot_width),
            y_for(val, plot_top, min_val, max_val, plot_height)
          )
        end
      end
    end

    private def draw_genome_overview(ctx, x, y, width, height, region : Region, chromosomes : Hash(String, UInt32))
      chromosome_size = chromosomes[region.chromosome]?
      return unless chromosome_size
      return if chromosome_size == 0 || width <= 0

      bar_brush = UIng::Area::Draw::Brush.new(:solid, 0.83, 0.85, 0.88, 1.0)
      outline_brush = UIng::Area::Draw::Brush.new(:solid, 0.32, 0.34, 0.36, 1.0)
      highlight_brush = UIng::Area::Draw::Brush.new(:solid, 0.9, 0.05, 0.05, 1.0)

      ctx.fill_path(bar_brush) do |path|
        path.add_rectangle(x, y + 6.0, width, height - 12.0)
      end

      ctx.stroke_path(outline_brush, thickness: 1.0) do |path|
        path.add_rectangle(x, y + 6.0, width, height - 12.0)
      end

      region_start = region.start0.clamp(0_u32, chromosome_size)
      region_end = region.end0_exclusive.clamp(region_start, chromosome_size)
      highlight_x = x + region_start.to_f / chromosome_size * width
      highlight_width = (region_end - region_start).to_f / chromosome_size * width
      highlight_width = 2.0 if highlight_width < 2.0

      ctx.stroke_path(highlight_brush, thickness: 2.0) do |path|
        path.add_rectangle(highlight_x, y + 3.0, highlight_width, height - 6.0)
      end
    end

    private def margin_for(width, height, show_axis_ticks)
      max_margin = show_axis_ticks ? LABEL_MARGIN : DEFAULT_MARGIN
      {max_margin, width / 4.0, height / 4.0}.min.clamp(MIN_MARGIN, max_margin)
    end

    private def x_for(pos, margin, min_pos, max_pos, plot_width)
      return margin + plot_width / 2.0 if max_pos == min_pos

      margin + (pos.to_f - min_pos) / (max_pos - min_pos) * plot_width
    end

    private def y_for(value, plot_top, min_val, max_val, plot_height)
      plot_top + plot_height - (value - min_val) / (max_val - min_val) * plot_height
    end

    private def y_range(min_val, max_val, from_zero)
      if from_zero
        padded_max = max_val > 0 ? max_val * 1.1 : 1.0
        return {0.0, padded_max}
      end

      val_range = max_val - min_val
      if val_range == 0
        min_val -= 0.5
        max_val += 0.5
      else
        padding = val_range * 0.1
        min_val -= padding
        max_val += padding
      end

      {min_val, max_val}
    end

    private def tick_values(min, max)
      return [min] if max == min

      step = (max - min) / (TICK_COUNT - 1)
      Array.new(TICK_COUNT) { |i| min + step * i }
    end

    private def draw_label(ctx, text, x, y, width, align)
      UIng::Area::AttributedString.open(text) do |attr_str|
        attr_str.set_attribute(UIng::Area::Attribute.new_color(0.15, 0.15, 0.15, 1.0), 0_u64, text.bytesize.to_u64)

        UIng::Area::Draw::TextLayout.open(
          string: attr_str,
          default_font: LABEL_FONT,
          width: width,
          align: align
        ) do |text_layout|
          ctx.draw_text_layout(text_layout, x, y)
        end
      end
    end

    private def format_position(value)
      value.round.to_u64.to_s
    end

    private def format_value(value)
      magnitude = value.abs

      if magnitude >= 1000 || (magnitude > 0 && magnitude < 0.01)
        "%.2e" % value
      elsif magnitude >= 10
        "%.1f" % value
      else
        "%.2f" % value
      end
    end
  end
end
