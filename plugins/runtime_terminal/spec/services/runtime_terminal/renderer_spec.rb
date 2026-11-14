require "rails_helper"
RSpec.describe RuntimeTerminal::Renderer do
  def render(source, cols: 8, rows: 3)
    screen = RuntimeTerminal::Screen.new(cols: cols, rows: rows)
    screen.apply(source)
    described_class.new(screen.snapshot).png
  end

  def image(source, cols: 8, rows: 3)
    Vips::Image.new_from_buffer(render(source, cols: cols, rows: rows), "")
  end

  def pixel(rendered, x, y)
    rendered.getpoint(x, y).first(3).map(&:round)
  end

  # Every pixel and metric assertion below reads the bundled fonts, and pango
  # only sees a font added through fontconfig when its fontmap is the
  # fontconfig-backed one. Homebrew's pango on macOS is built against the
  # CoreText backend instead, so libvips' FcConfigAppFontAddFile has no effect
  # there and no family name selects a bundled face at all: the renderer
  # silently draws with the host's default font, and these examples measure
  # that rather than the renderer. Detected by asking for a family that cannot
  # exist -- if the bundled family renders identical bytes, it was never
  # registered.
  #
  # Both faces are checked because they fail together and for the same reason,
  # and because a CJK cell with no bundled face becomes Pango's hexadecimal
  # tofu, which is exactly what the pinned glyph shape exists to catch.
  def bundled_fonts_selectable?
    # The probe itself asks Pango to resolve a deliberately nonexistent family
    # while loading the real font file. That is only needed for the CoreText
    # host this guard describes; on fontconfig-backed Linux it mutates the
    # process-global application-font cache on newer Pango versions and can
    # change which face later styled renders resolve. Linux is the supported
    # deterministic renderer and must always execute the metric assertions.
    return true unless RbConfig::CONFIG.fetch("host_os").match?(/darwin/i)
    return @bundled_fonts_selectable if defined?(@bundled_fonts_selectable)

    @bundled_fonts_selectable = [
      [ "DejaVu Sans Mono", described_class::FONT_PATH, "Mg" ],
      [ "Xiaolai SC", described_class::CJK_FONT_PATH, "\u754C" ]
    ].all? do |family, path, sample|
      markup = "<span fallback='false'>#{sample}</span>"
      bundled = Vips::Image.text(markup, font: "#{family} #{described_class::FONT_SIZE}", fontfile: path, rgba: false)
      bogus = Vips::Image.text(markup, font: "Nonexistent Spec Family #{described_class::FONT_SIZE}", fontfile: path, rgba: false)
      bundled.write_to_buffer(".png") != bogus.write_to_buffer(".png")
    end
  end

  def requires_bundled_fonts!
    skip "pango here ignores fontconfig app fonts, so no bundled face can be selected" unless bundled_fonts_selectable?
  end

  def include_pixel?(rendered, color)
    (0...rendered.height).any? do |y|
      (0...rendered.width).any? { |x| pixel(rendered, x, y) == color }
    end
  end

  def ink_bounds(rendered, col:, row: 0, width: 1)
    background = [ 30, 34, 42 ]
    pixel_width = width * described_class::CELL_WIDTH
    crop = rendered.crop(
      col * described_class::CELL_WIDTH,
      row * described_class::CELL_HEIGHT,
      pixel_width,
      described_class::CELL_HEIGHT
    )
    xs = []
    ys = []
    crop.write_to_memory.unpack("C*").each_slice(crop.bands).with_index do |channels, index|
      next if channels.first(3) == background

      xs << index % pixel_width
      ys << index / pixel_width
    end
    { x: xs.minmax, y: ys.minmax }
  end

  it "renders an exact viewport-sized deterministic PNG" do
    first = render("\e[31mred\e[0m\e[48;5;202m!\e[38;2;1;2;3m✓", cols: 8, rows: 2)
    second = render("\e[31mred\e[0m\e[48;5;202m!\e[38;2;1;2;3m✓", cols: 8, rows: 2)
    image = Vips::Image.new_from_buffer(first, "")

    expect(first).to eq(second)
    expect(first).to start_with("\x89PNG\r\n\x1a\n".b)
    expect([ image.width, image.height ]).to eq([ 8 * described_class::CELL_WIDTH, 2 * described_class::CELL_HEIGHT ])
  end

  it "uses one font baseline and fixed cell origins for mixed terminal text" do
    requires_bundled_fonts!

    rendered = image("\e[?25lSyrus inbox AZaz09!?", cols: 20, rows: 1)
    repeated = image("\e[?25liiii", cols: 5, rows: 1)

    non_descenders = [ 0, 2, 3, 4, *(6..10), *(12..19) ]
    baseline = ink_bounds(rendered, col: 0).fetch(:y).last
    expect(non_descenders.map { |col| ink_bounds(rendered, col: col).fetch(:y).last }.uniq).to eq([ baseline ])
    expect(ink_bounds(rendered, col: 1).fetch(:y).last).to be > baseline # y descends from the shared baseline
    expect((0...4).map { |col| ink_bounds(repeated, col: col) }.uniq.length).to eq(1)
  end

  it "keeps styled, combining, box-drawing, wide, and cursor cells on the row metrics" do
    requires_bundled_fonts!

    source = "\e[?25l\e[1mA\e[3mB\e[4mC\e[2mD\e[7mE\e[9mF\e[0m┌e\u0301界\e[?25h"
    rendered = image(source, cols: 12, rows: 1)

    styled_bounds = (0..5).map { |col| ink_bounds(rendered, col: col).fetch(:y) }
    baseline = styled_bounds.first.last
    expect(styled_bounds).to all(satisfy { |bounds| bounds.first < baseline && bounds.last >= baseline })
    # Fontconfig can rasterize the bundled box-drawing glyph either on the
    # shared baseline or one scanline below it. Both keep the glyph on the row
    # metrics; ending above the baseline is the displacement this guards against.
    expect(ink_bounds(rendered, col: 6).fetch(:y).last).to be >= baseline
    expect(ink_bounds(rendered, col: 7).fetch(:y).last).to eq(baseline) # combining text shares the baseline
    expect(ink_bounds(rendered, col: 8, width: 2).fetch(:y)).to all(be_between(0, described_class::CELL_HEIGHT - 1))
    expect(pixel(rendered, 10 * described_class::CELL_WIDTH + 5, 10)).not_to eq([ 30, 34, 42 ])
    expect(image("\e[?25l\e[8mhidden", cols: 6, rows: 1).avg).to eq(image("\e[?25l", cols: 6, rows: 1).avg)
  end

  it "renders a realistic multi-row TUI without per-glyph vertical oscillation" do
    requires_bundled_fonts!

    source = <<~ANSI.gsub("\n", "\r\n")
      \e[1;36m┌ Syrus inbox ─────────┐\e[0m
      │ JOB-42  Ready!       │
      │ owner: qa@example.io │
      └──────────────────────┘
    ANSI
    rendered = image("\e[?25l#{source}", cols: 24, rows: 4)

    expect([ rendered.width, rendered.height ]).to eq([ 240, 80 ])
    bounds = (2..4).map { |col| ink_bounds(rendered, col: col, row: 0).fetch(:y) }
    expect(bounds.uniq.length).to eq(1) # S, y, and r share one styled row origin and baseline
  end

  it "renders alternate-screen box drawing, wide Unicode, styles, and visible cursor state" do
    visible = render("\e[?1049h\e[1;4m┌─┐\e[2;1H│界│")
    hidden = render("\e[?1049h\e[1;4m┌─┐\e[2;1H│界│\e[?25l")

    expect(visible).not_to eq(hidden)
    expect(Vips::Image.new_from_buffer(visible, "").avg).to be_positive
  end

  it "maps ANSI, indexed, and RGB backgrounds to exact pixels" do
    rendered = image("\e[?25l\e[41m \e[48;5;202m \e[48;2;1;2;3m ", cols: 4, rows: 1)

    expect(pixel(rendered, 5, 10)).to eq([ 191, 97, 106 ])
    expect(pixel(rendered, 15, 10)).to eq([ 255, 95, 0 ])
    expect(pixel(rendered, 25, 10)).to eq([ 1, 2, 3 ])
    expect(pixel(rendered, 35, 10)).to eq([ 30, 34, 42 ])
  end

  it "maps ANSI, indexed, and RGB foregrounds to exact pixels" do
    rendered = image("\e[?25l\e[31m█\e[38;5;202m█\e[38;2;1;2;3m█", cols: 3, rows: 1)

    expect(include_pixel?(rendered, [ 191, 97, 106 ])).to be(true)
    expect(include_pixel?(rendered, [ 255, 95, 0 ])).to be(true)
    expect(include_pixel?(rendered, [ 1, 2, 3 ])).to be(true)
  end

  it "uses the bundled CJK glyph and clips it to its two-cell rectangle" do
    requires_bundled_fonts!

    rendered = image("\e[?25l界\e[48;2;9;8;7m ", cols: 3, rows: 1)
    cjk_cell = rendered.crop(0, 0, 2 * described_class::CELL_WIDTH, described_class::CELL_HEIGHT)
    bright_pixels_per_row = (0...cjk_cell.height).map do |y|
      (0...cjk_cell.width).count { |x| pixel(cjk_cell, x, y).first > 100 }
    end

    # This is the thresholded shape of 界 in the bundled Xiaolai subset. A
    # missing-glyph box also has bright pixels, so max/average assertions do
    # not catch Pango silently replacing it with hexadecimal tofu.
    expect(bright_pixels_per_row).to eq([ 0, 0, 0, 10, 5, 10, 6, 4, 10, 6, 5, 8, 5, 4, 3, 4, 0, 0, 0, 0 ])
    expect(pixel(rendered, 25, 10)).to eq([ 9, 8, 7 ])
  end
end
