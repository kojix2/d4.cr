require "uing"
require "./annotation"
require "./region"

module D4Plot
  class AnnotationRenderer
    GAP        = 14.0
    LANE       = 16.0
    MAX_HEIGHT = 96.0

    def self.height_for(track : AnnotationTrack?)
      return 0.0 if track.nil? || track.empty?
      return LANE * 2 if track.notice

      MAX_HEIGHT
    end

    def draw(ctx, track : AnnotationTrack?, region : Region?, plot_left, top, plot_width, height)
      return unless track
      return if height <= 0 || plot_width <= 0

      draw_axis(ctx, plot_left, top, plot_width)
      if notice = track.notice
        draw_notice(ctx, notice, plot_left, top + 12.0, plot_width)
      elsif region
        draw_features(ctx, track.features, region, plot_left, top, plot_width, height)
      end
    end

    private def draw_axis(ctx, x, y, width)
      brush = UIng::Area::Draw::Brush.new(:solid, 0.78, 0.80, 0.82, 1.0)
      ctx.stroke_path(brush, thickness: 1.0) do |path|
        path.new_figure(x, y)
        path.line_to(x + width, y)
      end
    end

    private def draw_notice(ctx, text, x, y, width)
      UIng::Area::AttributedString.open(text) do |attr_str|
        attr_str.set_attribute(UIng::Area::Attribute.new_color(0.45, 0.47, 0.50, 1.0), 0_u64, text.bytesize.to_u64)

        UIng::Area::Draw::TextLayout.open(
          string: attr_str,
          default_font: label_font,
          width: width,
          align: UIng::Area::Draw::TextAlign::Center
        ) do |text_layout|
          ctx.draw_text_layout(text_layout, x, y)
        end
      end
    end

    private def draw_features(ctx, features, region, plot_left, top, plot_width, height)
      lane_ends = [] of UInt32
      max_lanes = (height / LANE).floor.to_i

      features.sort_by { |feature| {feature.start1, feature.end1, feature.kind} }.each do |feature|
        lane = lane_for(feature, lane_ends)
        next if lane >= max_lanes

        draw_feature(ctx, feature, lane, region, plot_left, top, plot_width)
      end
    end

    private def lane_for(feature, lane_ends)
      lane_ends.each_with_index do |end1, index|
        if feature.start1 > end1
          lane_ends[index] = feature.end1
          return index
        end
      end

      lane_ends << feature.end1
      lane_ends.size - 1
    end

    private def draw_feature(ctx, feature, lane, region, plot_left, top, plot_width)
      min_pos = region.start1.to_f
      max_pos = region.end1.to_f
      x1 = x_for(feature.start1, plot_left, min_pos, max_pos, plot_width)
      x2 = x_for(feature.end1, plot_left, min_pos, max_pos, plot_width)
      x1, x2 = {x2, x1} if x2 < x1
      feature_width = {x2 - x1, 1.0}.max
      y = top + 6.0 + lane * LANE

      if feature.kind == "exon"
        draw_box(ctx, x1, y - 4.0, feature_width, 8.0, 0.12, 0.36, 0.52)
      else
        draw_line(ctx, x1, x2, y)
        draw_label(ctx, feature_label(feature), x1 + 3.0, y - 14.0, feature_width - 6.0) if feature_width > 34.0
      end
    end

    private def draw_line(ctx, x1, x2, y)
      brush = UIng::Area::Draw::Brush.new(:solid, 0.18, 0.28, 0.34, 1.0)
      ctx.stroke_path(brush, thickness: 1.0) do |path|
        path.new_figure(x1, y)
        path.line_to(x2, y)
      end
    end

    private def draw_box(ctx, x, y, width, height, red, green, blue)
      brush = UIng::Area::Draw::Brush.new(:solid, red, green, blue, 0.9)
      ctx.fill_path(brush) do |path|
        path.add_rectangle(x, y, width, height)
      end
    end

    private def draw_label(ctx, text, x, y, width)
      UIng::Area::AttributedString.open(text) do |attr_str|
        attr_str.set_attribute(UIng::Area::Attribute.new_color(0.15, 0.15, 0.15, 1.0), 0_u64, text.bytesize.to_u64)

        UIng::Area::Draw::TextLayout.open(
          string: attr_str,
          default_font: label_font,
          width: width,
          align: UIng::Area::Draw::TextAlign::Left
        ) do |text_layout|
          ctx.draw_text_layout(text_layout, x, y)
        end
      end
    end

    private def x_for(pos, margin, min_pos, max_pos, plot_width)
      return margin + plot_width / 2.0 if max_pos == min_pos

      margin + (pos.to_f - min_pos) / (max_pos - min_pos) * plot_width
    end

    private def feature_label(feature)
      feature.name || feature.kind
    end

    private def label_font
      @label_font ||= UIng::FontDescriptor.new(size: 11)
    end
  end
end
