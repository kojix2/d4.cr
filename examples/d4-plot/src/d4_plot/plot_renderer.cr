require "uing"
require "./data_sampler"
require "./plot_settings"

module D4Plot
  class PlotRenderer
    DEFAULT_MARGIN = 50.0
    MIN_MARGIN     = 12.0
    LABEL_MARGIN   = 58.0
    TICK_COUNT     =    5
    TICK_SIZE      =  5.0
    LABEL_FONT     = UIng::FontDescriptor.new(size: 11)

    def draw(params : UIng::Area::Draw::Params, data : Array(PlotPoint)?, show_axis_ticks : Bool = true, plot_color : PlotSettings::PlotColor = {0.0, 0.4, 0.8, 1.0})
      ctx = params.context
      width = params.area_width
      height = params.area_height
      margin = margin_for(width, height, show_axis_ticks)

      clear(ctx, width, height)

      return unless points = data
      return if points.empty?

      plot_width = width - 2 * margin
      plot_height = height - 2 * margin
      return if plot_width <= 0 || plot_height <= 0

      min_pos = points.first[0].to_f
      max_pos = points.last[0].to_f
      min_val = points.min_of(&.[1])
      max_val = points.max_of(&.[1])

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

      draw_axes(ctx, margin, plot_width, plot_height)
      draw_ticks(ctx, margin, min_pos, max_pos, min_val, max_val, plot_width, plot_height) if show_axis_ticks
      draw_area(ctx, points, margin, min_pos, max_pos, min_val, max_val, plot_width, plot_height, plot_color)
    end

    private def clear(ctx, width, height)
      bg_brush = UIng::Area::Draw::Brush.new(:solid, 1.0, 1.0, 1.0, 1.0)
      ctx.fill_path(bg_brush) do |path|
        path.add_rectangle(0, 0, width, height)
      end
    end

    private def draw_axes(ctx, margin, plot_width, plot_height)
      axis_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.0, 0.0, 1.0)
      ctx.stroke_path(axis_brush, thickness: 1.0) do |path|
        path.new_figure(margin, margin)
        path.line_to(margin, margin + plot_height)
        path.line_to(margin + plot_width, margin + plot_height)
      end
    end

    private def draw_ticks(ctx, margin, min_pos, max_pos, min_val, max_val, plot_width, plot_height)
      tick_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.0, 0.0, 1.0)

      tick_values(min_pos, max_pos).each do |pos|
        x = x_for(pos, margin, min_pos, max_pos, plot_width)
        y = margin + plot_height

        ctx.stroke_path(tick_brush, thickness: 1.0) do |path|
          path.new_figure(x, y)
          path.line_to(x, y + TICK_SIZE)
        end

        draw_label(ctx, format_position(pos), x - 36.0, y + 8.0, 72.0, UIng::Area::Draw::TextAlign::Center)
      end

      tick_values(min_val, max_val).each do |value|
        x = margin
        y = y_for(value, margin, min_val, max_val, plot_height)

        ctx.stroke_path(tick_brush, thickness: 1.0) do |path|
          path.new_figure(x - TICK_SIZE, y)
          path.line_to(x, y)
        end

        draw_label(ctx, format_value(value), 2.0, y - 7.0, margin - 10.0, UIng::Area::Draw::TextAlign::Right)
      end
    end

    private def draw_area(ctx, points, margin, min_pos, max_pos, min_val, max_val, plot_width, plot_height, plot_color)
      return unless points.size > 1

      red, green, blue, alpha = plot_color
      area_brush = UIng::Area::Draw::Brush.new(:solid, red, green, blue, alpha * 0.3)
      line_brush = UIng::Area::Draw::Brush.new(:solid, red, green, blue, alpha)

      ctx.fill_path(area_brush) do |path|
        first_x = x_for(points.first[0], margin, min_pos, max_pos, plot_width)
        path.new_figure(first_x, margin + plot_height)

        points.each do |pos, val|
          path.line_to(
            x_for(pos, margin, min_pos, max_pos, plot_width),
            y_for(val, margin, min_val, max_val, plot_height)
          )
        end

        last_x = x_for(points.last[0], margin, min_pos, max_pos, plot_width)
        path.line_to(last_x, margin + plot_height)
      end

      ctx.stroke_path(line_brush, thickness: 2.0) do |path|
        first_pos, first_val = points.first
        path.new_figure(
          x_for(first_pos, margin, min_pos, max_pos, plot_width),
          y_for(first_val, margin, min_val, max_val, plot_height)
        )

        points[1..].each do |pos, val|
          path.line_to(
            x_for(pos, margin, min_pos, max_pos, plot_width),
            y_for(val, margin, min_val, max_val, plot_height)
          )
        end
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

    private def y_for(value, margin, min_val, max_val, plot_height)
      margin + plot_height - (value - min_val) / (max_val - min_val) * plot_height
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
