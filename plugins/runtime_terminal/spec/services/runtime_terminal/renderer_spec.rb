require "rails_helper"
require "digest"

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

  def include_pixel?(rendered, color)
    (0...rendered.height).any? do |y|
      (0...rendered.width).any? { |x| pixel(rendered, x, y) == color }
    end
  end

  def ink_bounds(rendered, col:, row: 0, width: 1)
    background = [ 30, 34, 42 ]
    xs = []
    ys = []
    (col * described_class::CELL_WIDTH...(col + width) * described_class::CELL_WIDTH).each do |x|
      (row * described_class::CELL_HEIGHT...(row + 1) * described_class::CELL_HEIGHT).each do |y|
        next if pixel(rendered, x, y) == background

        xs << x - (col * described_class::CELL_WIDTH)
        ys << y - (row * described_class::CELL_HEIGHT)
      end
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
    rendered = image("\e[?25lSyrus inbox AZaz09!?", cols: 20, rows: 1)
    repeated = image("\e[?25liiii", cols: 5, rows: 1)

    expect(ink_bounds(rendered, col: 0)).to eq(x: [ 3, 9 ], y: [ 4, 15 ]) # S
    expect(ink_bounds(rendered, col: 1).fetch(:y)).to eq([ 7, 18 ]) # y descends from the baseline
    expect(ink_bounds(rendered, col: 2).fetch(:y)).to eq([ 7, 15 ]) # r is not vertically re-centered
    expect(ink_bounds(rendered, col: 12).fetch(:y)).to eq([ 4, 15 ]) # A
    expect(ink_bounds(rendered, col: 18).fetch(:x)).to eq([ 6, 7 ]) # ! keeps its logical x origin
    expect((0...4).map { |col| ink_bounds(repeated, col: col) }).to eq(Array.new(4, x: [ 3, 9 ], y: [ 4, 15 ]))
  end

  it "keeps styled, combining, box-drawing, wide, and cursor cells on the row metrics" do
    source = "\e[?25l\e[1mA\e[3mB\e[4mC\e[2mD\e[7mE\e[9mF\e[0m┌e\u0301界\e[?25h"
    rendered = image(source, cols: 12, rows: 1)

    expect((0..5).map { |col| ink_bounds(rendered, col: col).fetch(:y) }).to all(satisfy { |bounds| bounds.first <= 4 && bounds.last >= 15 })
    expect(ink_bounds(rendered, col: 6).fetch(:y)).to eq([ 9, 19 ])
    expect(ink_bounds(rendered, col: 7).fetch(:y)).to eq([ 3, 15 ])
    expect(ink_bounds(rendered, col: 8, width: 2).fetch(:y)).to eq([ 2, 16 ])
    expect(pixel(rendered, 10 * described_class::CELL_WIDTH + 5, 10)).not_to eq([ 30, 34, 42 ])
  end

  it "renders a realistic multi-row TUI without per-glyph vertical oscillation" do
    source = <<~ANSI.gsub("\n", "\r\n")
      \e[1;36m┌ Syrus inbox ─────────┐\e[0m
      │ JOB-42  Ready!       │
      │ owner: qa@example.io │
      └──────────────────────┘
    ANSI
    rendered = image("\e[?25l#{source}", cols: 24, rows: 4)

    expect([ rendered.width, rendered.height ]).to eq([ 240, 80 ])
    expect(ink_bounds(rendered, col: 2, row: 0).fetch(:y)).to eq([ 4, 15 ]) # S
    expect(ink_bounds(rendered, col: 3, row: 0).fetch(:y)).to eq([ 4, 15 ]) # y shares the styled row baseline
    expect(ink_bounds(rendered, col: 4, row: 0).fetch(:y)).to eq([ 4, 15 ]) # r
    expect(Digest::SHA256.hexdigest(rendered.write_to_buffer(".png", compression: 9, strip: true))).to eq("ff525dbf5b9dc02453959529acfdd55a07917cb7d825ba14d151f4fa328f253b")
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
    rendered = image("\e[?25l界\e[48;2;9;8;7m ", cols: 3, rows: 1)
    cjk_cell = rendered.crop(0, 0, 2 * described_class::CELL_WIDTH, described_class::CELL_HEIGHT)
    bright_pixels_per_row = (0...cjk_cell.height).map do |y|
      (0...cjk_cell.width).count { |x| pixel(cjk_cell, x, y).first > 100 }
    end

    # This is the thresholded shape of 界 in the bundled Xiaolai subset. A
    # missing-glyph box also has bright pixels, so max/average assertions do
    # not catch Pango silently replacing it with hexadecimal tofu.
    expect(bright_pixels_per_row).to eq([ 0, 0, 0, 10, 5, 10, 6, 4, 10, 6, 5, 7, 4, 4, 3, 4, 0, 0, 0, 0 ])
    expect(pixel(rendered, 25, 10)).to eq([ 9, 8, 7 ])
  end
end
