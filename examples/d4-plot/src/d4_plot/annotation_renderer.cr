require "uing"
require "./annotation"
require "./region"

module D4Plot
  class AnnotationRenderer
    GAP        =  14.0
    LANE       =  24.0
    MAX_HEIGHT = 120.0

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
        ctx.save
        ctx.clip_path { |path| path.add_rectangle(plot_left, top, plot_width, height) }
        draw_features(ctx, track.features, region, plot_left, top, plot_width, height)
        ctx.restore
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
      max_lanes = (height / LANE).floor.to_i - 1
      hidden = 0

      features.sort_by { |feature| {feature.start1, feature.end1, feature.kind} }.each do |feature|
        lane = lane_for(feature, lane_ends)
        if lane >= max_lanes
          hidden += 1
          next
        end

        draw_feature(ctx, feature, lane, region, plot_left, top, plot_width)
      end
      if hidden > 0
        draw_notice(ctx, "#{hidden} additional features overlap these lanes; zoom in to inspect them", plot_left, top + height - 17, plot_width)
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
      x1 = plot_left + (feature.start1.to_i64 - 1 - region.start0).to_f / region.length * plot_width
      x2 = plot_left + (feature.end1.to_i64 - region.start0).to_f / region.length * plot_width
      x1 = x1.clamp(plot_left, plot_left + plot_width)
      x2 = x2.clamp(plot_left, plot_left + plot_width)
      feature_width = {x2 - x1, 1.0}.max
      y = top + 18.0 + lane * LANE

      if feature.kind == "exon"
        draw_box(ctx, x1, y - 4.0, feature_width, 8.0, 0.12, 0.36, 0.52)
      else
        draw_line(ctx, x1, x2, y, feature.strand)
        draw_label(ctx, feature.name || feature.kind, x1 + 3.0, y - 18.0, feature_width - 6.0) if feature_width > 34.0
      end
    end

    private def draw_line(ctx, x1, x2, y, strand)
      brush = UIng::Area::Draw::Brush.new(:solid, 0.18, 0.28, 0.34, 1.0)
      ctx.stroke_path(brush, thickness: 1.0) do |path|
        path.new_figure(x1, y)
        path.line_to(x2, y)
        if strand && x2 - x1 > 12
          direction = strand == "+" ? 1.0 : -1.0
          tip = strand == "+" ? x2 - 2 : x1 + 2
          path.new_figure(tip - 4 * direction, y - 3)
          path.line_to(tip, y)
          path.line_to(tip - 4 * direction, y + 3)
        end
      end
    end

    private def draw_box(ctx, x, y, width, height, red, green, blue)
      brush = UIng::Area::Draw::Brush.new(:solid, red, green, blue, 0.9)
      ctx.fill_path(brush) do |path|
        path.add_rectangle(x, y, width, height)
      end
    end

    private def draw_label(ctx, text, x, y, width)
      # Keep names on one lane; TextLayout otherwise wraps long names across
      # neighbouring features. Strand is drawn on the interval itself.
      characters = Math.max((width / 8).floor.to_i, 2)
      text = text[0, characters - 1] + "…" if text.size > characters
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

    private def label_font
      @label_font ||= UIng::FontDescriptor.new(size: 11)
    end
  end
end
