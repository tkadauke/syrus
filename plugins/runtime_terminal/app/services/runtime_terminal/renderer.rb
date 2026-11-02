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
    CJK_FONT_PATH = File.expand_path("../../../assets/XiaolaiCjkSubset.ttf", __dir__)
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
        image = image.composite(overlay, "over", x: cell.fetch(:x), y: cell.fetch(:y))
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
      unless styles.include?("hidden") || cell.fetch(:text) == " "
        mask = text_mask(cell.fetch(:text), styles, cell_width, wide: cell.fetch(:width) == 2)
      end
      { x: x, y: y, width: cell_width, foreground: foreground, background: background, mask: mask }
    end

    def text_mask(text, styles, cell_width, wide:)
      markup = CGI.escapeHTML(text)
      markup = "<b>#{markup}</b>" if styles.include?("bold")
      markup = "<i>#{markup}</i>" if styles.include?("italic")
      markup = "<u>#{markup}</u>" if styles.include?("underline")
      markup = "<s>#{markup}</s>" if styles.include?("strikethrough")
      markup = "<span alpha='60%'>#{markup}</span>" if styles.include?("dim")
      markup = "<span fallback='false'>#{markup}</span>"
      family, path = wide ? [ "Xiaolai SC", CJK_FONT_PATH ] : [ "DejaVu Sans Mono", FONT_PATH ]
      glyph = Vips::Image.text(markup, font: "#{family} #{FONT_SIZE}", fontfile: path, rgba: false)
      clip_to_cell(glyph, cell_width)
    end

    def clip_to_cell(glyph, cell_width)
      left = (cell_width - glyph.width) / 2
      top = (CELL_HEIGHT - glyph.height) / 2
      source_left = [ -left, 0 ].max
      source_top = [ -top, 0 ].max
      target_left = [ left, 0 ].max
      target_top = [ top, 0 ].max
      clipped_width = [ glyph.width - source_left, cell_width - target_left ].min
      clipped_height = [ glyph.height - source_top, CELL_HEIGHT - target_top ].min
      canvas = Vips::Image.black(cell_width, CELL_HEIGHT)
      return canvas unless clipped_width.positive? && clipped_height.positive?

      canvas.insert(glyph.crop(source_left, source_top, clipped_width, clipped_height), target_left, target_top)
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
