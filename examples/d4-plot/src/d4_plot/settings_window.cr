require "uing"
require "./plot_settings"

module D4Plot
  class SettingsWindow
    @window : UIng::Window
    @sum_index_checkbox : UIng::Checkbox
    @axis_ticks_checkbox : UIng::Checkbox
    @y_axis_from_zero_checkbox : UIng::Checkbox
    @annotation_limit_entry : UIng::Entry
    @plot_color_button : UIng::ColorButton
    @apply_button : UIng::Button
    @close_button : UIng::Button

    def initialize(@settings : PlotSettings, @parent : UIng::Window, @on_apply : Proc(Nil), @on_close : Proc(Nil))
      @window = UIng::Window.new("Settings", 340, 210, margined: true)
      @sum_index_checkbox = UIng::Checkbox.new("Use sum index when available")
      @sum_index_checkbox.checked = @settings.use_sum_index?
      @axis_ticks_checkbox = UIng::Checkbox.new("Show axis ticks and labels")
      @axis_ticks_checkbox.checked = @settings.show_axis_ticks?
      @y_axis_from_zero_checkbox = UIng::Checkbox.new("Start Y axis at zero")
      @y_axis_from_zero_checkbox.checked = @settings.y_axis_from_zero?
      @annotation_limit_entry = UIng::Entry.new
      @annotation_limit_entry.text = @settings.annotation_feature_limit.to_s
      @plot_color_button = UIng::ColorButton.new
      @plot_color_button.set_color(*@settings.plot_color)
      @apply_button = UIng::Button.new("Apply")
      @close_button = UIng::Button.new("Close")

      setup_ui
      setup_handlers
    end

    def show
      @window.show
      center_on_parent
    end

    def destroy
      @window.destroy
    end

    private def setup_ui
      vbox = UIng::Box.new(:vertical)
      vbox.padded = true

      group = UIng::Group.new("Plot")
      group.margined = true

      form = UIng::Form.new
      form.padded = true
      form.append("", @sum_index_checkbox)
      form.append("", @axis_ticks_checkbox)
      form.append("", @y_axis_from_zero_checkbox)
      form.append("Annotation limit", @annotation_limit_entry)
      form.append("Plot color", @plot_color_button)
      group.child = form

      buttons = UIng::Box.new(:horizontal)
      buttons.padded = true
      buttons.append(@apply_button, false)
      buttons.append(@close_button, false)

      vbox.append(group, true)
      vbox.append(buttons, false)
      @window.child = vbox
    end

    private def setup_handlers
      @apply_button.on_clicked do
        apply_settings
      end

      @close_button.on_clicked do
        close
      end

      @window.on_closing do
        @on_close.call
        true
      end
    end

    private def apply_settings
      @settings.use_sum_index = @sum_index_checkbox.checked?
      @settings.show_axis_ticks = @axis_ticks_checkbox.checked?
      @settings.y_axis_from_zero = @y_axis_from_zero_checkbox.checked?
      @settings.annotation_feature_limit = annotation_limit_from_entry
      @annotation_limit_entry.text = @settings.annotation_feature_limit.to_s
      @settings.plot_color = @plot_color_button.color
      @on_apply.call
    end

    private def annotation_limit_from_entry
      value = (@annotation_limit_entry.text || "").to_i?
      return @settings.annotation_feature_limit unless value

      {value, 1}.max
    end

    private def close
      @on_close.call
      destroy
    end

    private def center_on_parent
      parent_x, parent_y = @parent.position
      parent_width, parent_height = @parent.content_size
      width, height = @window.content_size

      x = parent_x + parent_width / 2 - width / 2
      y = parent_y + parent_height / 2 - height / 2
      @window.set_position(x.to_i, y.to_i)
    end
  end
end
