require "uing"
require "./data_sampler"

module D4Plot
  class PlotRenderer
    WIDTH  = 800.0
    HEIGHT = 600.0
    MARGIN =  50.0

    def draw(ctx : UIng::Area::Draw::Context, data : Array(PlotPoint)?)
      clear(ctx)

      return unless points = data
      return if points.empty?

      plot_width = WIDTH - 2 * MARGIN
      plot_height = HEIGHT - 2 * MARGIN

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

      draw_axes(ctx, plot_width, plot_height)
      draw_area(ctx, points, min_pos, max_pos, min_val, max_val, plot_width, plot_height)
    end

    private def clear(ctx)
      bg_brush = UIng::Area::Draw::Brush.new(:solid, 1.0, 1.0, 1.0, 1.0)
      ctx.fill_path(bg_brush) do |path|
        path.add_rectangle(0, 0, WIDTH, HEIGHT)
      end
    end

    private def draw_axes(ctx, plot_width, plot_height)
      axis_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.0, 0.0, 1.0)
      ctx.stroke_path(axis_brush, thickness: 1.0) do |path|
        path.new_figure(MARGIN, MARGIN)
        path.line_to(MARGIN, MARGIN + plot_height)
        path.line_to(MARGIN + plot_width, MARGIN + plot_height)
      end
    end

    private def draw_area(ctx, points, min_pos, max_pos, min_val, max_val, plot_width, plot_height)
      return unless points.size > 1

      area_brush = UIng::Area::Draw::Brush.new(:solid, 0.2, 0.6, 1.0, 0.3)
      line_brush = UIng::Area::Draw::Brush.new(:solid, 0.0, 0.4, 0.8, 1.0)

      ctx.fill_path(area_brush) do |path|
        first_x = x_for(points.first[0], min_pos, max_pos, plot_width)
        path.new_figure(first_x, MARGIN + plot_height)

        points.each do |pos, val|
          path.line_to(
            x_for(pos, min_pos, max_pos, plot_width),
            y_for(val, min_val, max_val, plot_height)
          )
        end

        last_x = x_for(points.last[0], min_pos, max_pos, plot_width)
        path.line_to(last_x, MARGIN + plot_height)
      end

      ctx.stroke_path(line_brush, thickness: 2.0) do |path|
        first_pos, first_val = points.first
        path.new_figure(
          x_for(first_pos, min_pos, max_pos, plot_width),
          y_for(first_val, min_val, max_val, plot_height)
        )

        points[1..].each do |pos, val|
          path.line_to(
            x_for(pos, min_pos, max_pos, plot_width),
            y_for(val, min_val, max_val, plot_height)
          )
        end
      end
    end

    private def x_for(pos, min_pos, max_pos, plot_width)
      MARGIN + (pos.to_f - min_pos) / (max_pos - min_pos) * plot_width
    end

    private def y_for(value, min_val, max_val, plot_height)
      MARGIN + plot_height - (value - min_val) / (max_val - min_val) * plot_height
    end
  end
end
