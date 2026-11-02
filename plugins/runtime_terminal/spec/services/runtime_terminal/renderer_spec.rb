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

  def include_pixel?(rendered, color)
    (0...rendered.height).any? do |y|
      (0...rendered.width).any? { |x| pixel(rendered, x, y) == color }
    end
  end

  it "renders an exact viewport-sized deterministic PNG" do
    first = render("\e[31mred\e[0m\e[48;5;202m!\e[38;2;1;2;3m✓", cols: 8, rows: 2)
    second = render("\e[31mred\e[0m\e[48;5;202m!\e[38;2;1;2;3m✓", cols: 8, rows: 2)
    image = Vips::Image.new_from_buffer(first, "")

    expect(first).to eq(second)
    expect(first).to start_with("\x89PNG\r\n\x1a\n".b)
    expect([ image.width, image.height ]).to eq([ 8 * described_class::CELL_WIDTH, 2 * described_class::CELL_HEIGHT ])
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
    rendered = image("\e[?25l\e[31mM\e[38;5;202mM\e[38;2;1;2;3mM", cols: 3, rows: 1)

    expect(include_pixel?(rendered, [ 191, 97, 106 ])).to be(true)
    expect(include_pixel?(rendered, [ 255, 95, 0 ])).to be(true)
    expect(include_pixel?(rendered, [ 1, 2, 3 ])).to be(true)
  end

  it "uses the bundled CJK glyph and clips it to its two-cell rectangle" do
    rendered = image("\e[?25l界\e[48;2;9;8;7m ", cols: 3, rows: 1)
    cjk_cell = rendered.crop(0, 0, 2 * described_class::CELL_WIDTH, described_class::CELL_HEIGHT)

    expect(cjk_cell.max).to be > 200
    expect(pixel(rendered, 25, 10)).to eq([ 9, 8, 7 ])
  end
end
