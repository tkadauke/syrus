require "rails_helper"

RSpec.describe RuntimeTerminal::Renderer do
  def render(source, cols: 8, rows: 3)
    screen = RuntimeTerminal::Screen.new(cols: cols, rows: rows)
    screen.apply(source)
    described_class.new(screen.snapshot).png
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
end
