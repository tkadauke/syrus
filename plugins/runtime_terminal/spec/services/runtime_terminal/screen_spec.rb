require "rails_helper"

RSpec.describe RuntimeTerminal::Screen do
  def row(snapshot, index = 0)
    snapshot.fetch(:lines).fetch(index)
  end

  it "models cursor addressing, overwritten cells, clearing, and generations" do
    screen = described_class.new(cols: 8, rows: 3)

    screen.apply("hello")
    screen.apply("\e[1;2HX\e[K")

    expect(screen.snapshot.fetch(:generation)).to eq(2)
    expect(row(screen.snapshot).fetch(:text)).to eq("hX")
    expect(screen.snapshot.fetch(:cursor)).to eq(row: 0, col: 2, visible: true)
  end

  it "keeps primary content while an alternate-screen TUI is active" do
    screen = described_class.new(cols: 10, rows: 2)
    screen.apply("shell\e[?1049h\e[?25l┌─┐\e[2;1H│界│")

    alternate = screen.snapshot
    expect(alternate.fetch(:alternate)).to be true
    expect(alternate.fetch(:cursor).fetch(:visible)).to be false
    expect(row(alternate).fetch(:text)).to eq("┌─┐")
    expect(row(alternate, 1).fetch(:text)).to eq("│界│")
    expect(row(alternate, 1).fetch(:cells).map { |cell| cell.fetch(:width) }).to include(2, 0)

    screen.apply("\e[?1049l")
    expect(screen.snapshot.fetch(:alternate)).to be false
    expect(row(screen.snapshot).fetch(:text)).to eq("shell")
  end

  it "preserves combining characters and ANSI, indexed, and true-color attributes" do
    screen = described_class.new(cols: 8, rows: 2)
    screen.apply("\e[1;31mA\e[38;5;202mB\e[48;2;1;2;3m" + "e\u0301")

    cells = row(screen.snapshot).fetch(:cells)
    expect(cells[0]).to include(text: "A", foreground: { mode: "ansi", value: 1 }, styles: [ "bold" ])
    expect(cells[1]).to include(text: "B", foreground: { mode: "indexed", value: 202 })
    expect(cells[2]).to include(text: "é", background: { mode: "rgb", r: 1, g: 2, b: 3 })
  end

  it "resizes both buffers and keeps bounded primary scrollback" do
    screen = described_class.new(cols: 4, rows: 2, scrollback_limit: 2)
    screen.apply("1\n2\n3\n4")
    screen.resize(6, 3)

    snapshot = screen.snapshot
    expect(snapshot).to include(cols: 6, rows: 3, generation: 2)
    expect(snapshot.fetch(:scrollback).length).to be <= 2
    expect(snapshot.fetch(:lines).all? { |line| line.fetch(:cells).length == 6 }).to be true
  end

  it "accepts a UTF-8 glyph split across output frames" do
    screen = described_class.new(cols: 4, rows: 1)
    bytes = "界".b

    screen.apply(bytes.byteslice(0, 1))
    screen.apply(bytes.byteslice(1, 2))

    expect(row(screen.snapshot).fetch(:text)).to eq("界")
  end
end
