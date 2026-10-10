require "uing"

module D4Plot
  # Owns the native toolbar and its borrowed images. Detach before freeing.
  class Toolbar
    getter native = UIng::Toolbar.new
    getter open : UIng::ToolbarItem
    getter annotations : UIng::ToolbarItem
    getter export : UIng::ToolbarItem
    getter back : UIng::ToolbarItem
    getter forward : UIng::ToolbarItem
    getter left : UIng::ToolbarItem
    getter right : UIng::ToolbarItem
    getter zoom_in : UIng::ToolbarItem
    getter zoom_out : UIng::ToolbarItem
    getter whole : UIng::ToolbarItem
    getter cancel : UIng::ToolbarItem
    getter settings : UIng::ToolbarItem
    @images = [] of UIng::Image

    def initialize
      @native.display_mode = UIng::Toolbar::DisplayMode::IconAndTextVertical
      @open = button("Open", "Open a D4 file", [[{2, 16}, {2, 4}, {8, 4}, {10, 6}, {18, 6}, {18, 16}, {2, 16}], [{2, 9}, {18, 9}]])
      @annotations = button("Annotations", "Load GFF3, GTF or BED from the same reference assembly", [[{2, 6}, {18, 6}], [{5, 3}, {5, 9}], [{8, 3}, {8, 9}], [{2, 14}, {18, 14}], [{12, 11}, {12, 17}], [{15, 11}, {15, 17}]])
      @export = button("Export bins", "Save displayed bin means as bedGraph (0-based, half-open)", [[{10, 2}, {10, 12}], [{6, 8}, {10, 12}, {14, 8}], [{3, 13}, {3, 17}, {17, 17}, {17, 13}]])
      @native.append_separator
      @back = button("Back", "Return to the previous viewed region", [[{8, 4}, {2, 10}, {8, 16}], [{2, 10}, {18, 10}]])
      @forward = button("Forward", "Restore the next viewed region", [[{12, 4}, {18, 10}, {12, 16}], [{2, 10}, {18, 10}]])
      @native.append_separator
      @left = button("Left", "Move left by half the visible range (plot key: Left)", [[{8, 5}, {3, 10}, {8, 15}], [{3, 10}, {14, 10}], [{17, 4}, {17, 16}]])
      @right = button("Right", "Move right by half the visible range (plot key: Right)", [[{12, 5}, {17, 10}, {12, 15}], [{6, 10}, {17, 10}], [{3, 4}, {3, 16}]])
      lens = [[{4, 3}, {10, 3}, {13, 6}, {13, 10}, {10, 13}, {4, 13}, {1, 10}, {1, 6}, {4, 3}], [{12, 12}, {18, 18}], [{4, 8}, {10, 8}]]
      @zoom_out = button("Zoom out", "Show twice the range (plot key: −)", lens)
      @zoom_in = button("Zoom in", "Show half the range (plot key: +)", lens + [[{7, 5}, {7, 11}]])
      @whole = button("Whole chr", "Show the whole chromosome (plot key: Home)", [[{2, 4}, {2, 16}], [{18, 4}, {18, 16}], [{2, 10}, {18, 10}], [{6, 6}, {2, 10}, {6, 14}], [{14, 6}, {18, 10}, {14, 14}]])
      @cancel = button("Cancel", "Cancel loading and keep the last completed plot (plot key: Esc)", [[{5, 5}, {15, 15}], [{5, 15}, {15, 5}]])
      @native.append_separator
      @settings = button("Display", "Set bin resolution, Y scale and reference lines", [[{3, 5}, {17, 5}], [{3, 10}, {17, 10}], [{3, 15}, {17, 15}], [{7, 3}, {7, 7}], [{13, 8}, {13, 12}], [{7, 13}, {7, 17}]])
    end

    def free
      @native.free
      @images.each &.free
      @images.clear
    end

    private def button(text, tooltip, strokes) : UIng::ToolbarItem
      icon = icon(strokes)
      @images << icon
      item = @native.append_button(text, icon)
      item.tooltip = tooltip
      item
    end

    # Small line icons at 1× and 2×, with no image files or decoding dependency.
    private def icon(strokes) : UIng::Image
      image = UIng::Image.new(20, 20)
      {1, 2}.each do |scale|
        size = 20 * scale
        pixels = Bytes.new(size * size * 4)
        size.times do |y|
          size.times do |x|
            distance = Float64::INFINITY
            strokes.each do |stroke|
              stroke.each_cons_pair do |a, b|
                dx, dy = b[0] - a[0], b[1] - a[1]
                px, py = (x + 0.5) / scale - a[0], (y + 0.5) / scale - a[1]
                fraction = ((px * dx + py * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0)
                distance = Math.min(distance, Math.sqrt((px - fraction * dx)**2 + (py - fraction * dy)**2))
              end
            end
            offset = (y * size + x) * 4
            pixels[offset] = 50
            pixels[offset + 1] = 129
            pixels[offset + 2] = 181
            alpha = ((0.85 - distance) * scale + 0.5).clamp(0.0, 1.0)
            pixels[offset + 3] = (alpha * 255).round.to_u8
          end
        end
        image.append(pixels, size, size, size * 4)
      end
      image
    end
  end
end
