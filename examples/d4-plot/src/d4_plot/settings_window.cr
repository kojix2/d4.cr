require "uing"
require "./plot_settings"

module D4Plot
  class SettingsWindow
    @window : UIng::Window
    @point_count_spinbox : UIng::Spinbox
    @axis_ticks_checkbox : UIng::Checkbox
    @apply_button : UIng::Button
    @close_button : UIng::Button

    def initialize(@settings : PlotSettings, @parent : UIng::Window, @on_apply : Proc(Nil), @on_close : Proc(Nil))
      @window = UIng::Window.new("Settings", 320, 160, margined: true)
      @point_count_spinbox = UIng::Spinbox.new(16, 4096, @settings.point_count)
      @axis_ticks_checkbox = UIng::Checkbox.new("Show axis ticks and labels")
      @axis_ticks_checkbox.checked = @settings.show_axis_ticks?
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
      form.append("Sampling points", @point_count_spinbox)
      form.append("", @axis_ticks_checkbox)
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
      @settings.point_count = @point_count_spinbox.value
      @settings.show_axis_ticks = @axis_ticks_checkbox.checked?
      @on_apply.call
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
