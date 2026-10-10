require "uing"
require "./plot_settings"

module D4Plot
  class SettingsWindow
    def initialize(@settings : PlotSettings, @parent : UIng::Window, @on_apply : Proc(Nil), @on_close : Proc(Nil))
      @window = UIng::Window.new("Display settings", 420, 390, margined: true)
      @bins = UIng::Spinbox.new(16, 4096, @settings.point_count)
      @auto = UIng::Checkbox.new("Automatically scale each view")
      @auto.checked = @settings.y_min.nil? && @settings.y_max.nil?
      @zero = UIng::Checkbox.new("Include zero in automatic scale")
      @zero.checked = @settings.y_axis_from_zero?
      @min = UIng::Entry.new
      @min.text = (@settings.y_min || 0.0).to_s
      @max = UIng::Entry.new
      @max.text = (@settings.y_max || 100.0).to_s
      @lines = UIng::Entry.new
      @lines.text = @settings.h_lines.join(", ")
      @color = UIng::ColorButton.new
      @color.set_color(*@settings.plot_color)
      @limit = UIng::Spinbox.new(1, 5000, @settings.annotation_feature_limit)
      form = UIng::Form.new
      form.padded = true
      form.append("Display bins", @bins)
      form.append("Y scale", @auto)
      form.append("", @zero)
      form.append("Fixed minimum", @min)
      form.append("Fixed maximum", @max)
      form.append("Reference lines (comma separated)", @lines)
      form.append("Signal color", @color)
      form.append("Annotation feature limit", @limit)
      root = UIng::Box.new(:vertical)
      root.padded = true
      root.append(form, true)
      root.append(UIng::Label.new("Bins show means: zoom in to inspect local peaks.\nFixed scales help compare different regions."), false)
      buttons = UIng::Box.new(:horizontal)
      buttons.padded = true
      apply = UIng::Button.new("Apply")
      close = UIng::Button.new("Close")
      buttons.append(apply, false)
      buttons.append(close, false)
      root.append(buttons, false)
      @window.child = root
      apply.on_clicked { apply_settings }
      close.on_clicked { @on_close.call; destroy }
      @window.on_closing { @on_close.call; true }
      @auto.on_toggled { sync_scale_controls }
      sync_scale_controls
    end

    def show
      @window.show
    end

    def destroy
      @window.destroy
    end

    private def sync_scale_controls : Nil
      if @auto.checked?
        @min.disable
        @max.disable
        @zero.enable
      else
        @min.enable
        @max.enable
        @zero.disable
      end
    end

    private def number(text : String) : Float64
      value = text.strip.to_f?
      raise ArgumentError.new("Enter a finite number: #{text.inspect}") unless value && value.finite?
      value
    end

    private def apply_settings : Nil
      minimum = @auto.checked? ? nil : number(@min.text || "")
      maximum = @auto.checked? ? nil : number(@max.text || "")
      if minimum && maximum && maximum <= minimum
        raise ArgumentError.new("Fixed maximum must be greater than fixed minimum.")
      end
      lines = (@lines.text || "").split(/[\s,;]+/).reject(&.empty?).map { |text| number(text) }.uniq!.sort!
      @settings.point_count = @bins.value
      @settings.y_min = minimum
      @settings.y_max = maximum
      @settings.y_axis_from_zero = @zero.checked?
      @settings.h_lines = lines
      @settings.plot_color = @color.color
      @settings.annotation_feature_limit = @limit.value
      @on_apply.call
    rescue ex : ArgumentError
      @window.msg_box_error("Check display settings", ex.message || "Invalid settings")
    end
  end
end
