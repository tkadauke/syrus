require "cgi"
require "vips"

module RuntimeTerminal
  # Deterministic terminal-surface renderer. It consumes Screen#snapshot's
  # cells directly; no ANSI stream is reparsed and no browser chrome is added.
  class Renderer
    CELL_WIDTH = 10
    CELL_HEIGHT = 20
    FONT_SIZE = 16
    FONT_PATH = File.expand_path("../../../assets/DejaVuSansMono.ttf", __dir__)
    DEFAULT_FOREGROUND = "#d8dee9"
    DEFAULT_BACKGROUND = "#1e222a"
    ANSI = %w[
      #2e3440 #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #88c0d0 #e5e9f0
      #4c566a #bf616a #a3be8c #ebcb8b #81a1c1 #b48ead #8fbcbb #eceff4
    ].freeze

    def initialize(snapshot)
      @snapshot = snapshot
    end

    def png
      image = Vips::Image.black(width, height).new_from_image(rgba(DEFAULT_BACKGROUND)).copy(interpretation: "srgb")
      rendered_cells.each do |cell|
        unless cell.fetch(:background) == DEFAULT_BACKGROUND
          image = image.draw_rect(rgba(cell.fetch(:background)), cell.fetch(:x), cell.fetch(:y), cell.fetch(:width), CELL_HEIGHT, fill: true)
        end
        next unless cell[:mask]

        mask = cell.fetch(:mask)
        overlay = mask.new_from_image(rgb(cell.fetch(:foreground))).copy(interpretation: "srgb").bandjoin(mask)
        image = image.composite(overlay, "over", x: cell.fetch(:x), y: cell.fetch(:y) + ((CELL_HEIGHT - mask.height) / 2))
      end
      image.pngsave_buffer(compression: 9, strip: true)
    end

    private

    attr_reader :snapshot

    def rendered_cells
      snapshot.fetch(:lines).each_with_index.flat_map do |line, row|
        line.fetch(:cells).each_with_index.filter_map { |cell, col| render_cell(cell, row, col) }
      end
    end

    def render_cell(cell, row, col)
      return if cell.fetch(:width).zero?

      styles = cell.fetch(:styles)
      foreground = color(cell[:foreground], DEFAULT_FOREGROUND)
      background = color(cell[:background], DEFAULT_BACKGROUND)
      foreground, background = background, foreground if styles.include?("inverse")
      cursor = snapshot.fetch(:cursor)
      if cursor.fetch(:visible) && cursor.fetch(:row) == row && cursor.fetch(:col) == col
        foreground, background = background, foreground
      end
      cell_width = CELL_WIDTH * cell.fetch(:width)
      x = col * CELL_WIDTH
      y = row * CELL_HEIGHT
      mask = text_mask(cell.fetch(:text), styles, foreground) unless styles.include?("hidden") || cell.fetch(:text) == " "
      { x: x, y: y, width: cell_width, foreground: foreground, background: background, mask: mask }
    end

    def text_mask(text, styles, _foreground)
      markup = CGI.escapeHTML(text)
      markup = "<b>#{markup}</b>" if styles.include?("bold")
      markup = "<i>#{markup}</i>" if styles.include?("italic")
      markup = "<u>#{markup}</u>" if styles.include?("underline")
      markup = "<s>#{markup}</s>" if styles.include?("strikethrough")
      markup = "<span alpha='60%'>#{markup}</span>" if styles.include?("dim")
      Vips::Image.text(markup, font: "DejaVu Sans Mono #{FONT_SIZE}", fontfile: FONT_PATH, rgba: false)
    end

    def color(value, fallback)
      return fallback unless value
      return ANSI.fetch(value.fetch(:value).clamp(0, ANSI.length - 1)) if value.fetch(:mode) == "ansi"
      return indexed_color(value.fetch(:value)) if value.fetch(:mode) == "indexed"

      format("#%02x%02x%02x", value.fetch(:r).clamp(0, 255), value.fetch(:g).clamp(0, 255), value.fetch(:b).clamp(0, 255))
    end

    def indexed_color(index)
      index = index.clamp(0, 255)
      return ANSI[index] if index < 16
      return format("#%02x%02x%02x", *Array.new(3, 8 + (index - 232) * 10)) if index >= 232

      value = index - 16
      components = [ value / 36, (value / 6) % 6, value % 6 ].map { |part| part.zero? ? 0 : 55 + part * 40 }
      format("#%02x%02x%02x", *components)
    end

    def rgb(hex)
      hex.delete_prefix("#").scan(/../).map { |component| component.to_i(16) }
    end

    def rgba(hex) = rgb(hex) + [ 255 ]

    def width = snapshot.fetch(:cols) * CELL_WIDTH
    def height = snapshot.fetch(:rows) * CELL_HEIGHT
  end
end
