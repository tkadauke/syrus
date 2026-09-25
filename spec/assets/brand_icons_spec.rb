# frozen_string_literal: true

require "spec_helper"

# The winged-stylus brand mark (issue #933) ships at fixed sizes that the
# layout, the PWA manifest, and electron-builder all rely on. Dimensions are
# read straight from the PNG IHDR header — no image library needed.
RSpec.describe "brand icons" do
  let(:repo_root) { File.expand_path("../..", __dir__) }

  def png_dimensions(relative_path)
    File.open(File.join(repo_root, relative_path), "rb") do |file|
      header = file.read(24)
      raise "#{relative_path} is not a PNG" unless header[0, 8] == "\x89PNG\r\n\n".b
      header[16, 8].unpack("N2")
    end
  end

  it "ships the favicon and PWA icons at the sizes the layout and manifest declare" do
    expect(png_dimensions("public/icon.png")).to eq([512, 512])
    expect(png_dimensions("public/icon-192.png")).to eq([192, 192])
    expect(png_dimensions("public/icon-512.png")).to eq([512, 512])
  end

  it "does not ship the base64-PNG-wrapped SVG favicon" do
    # public/icon.svg was a 133KB SVG that merely base64-embedded the PNG —
    # strictly worse than the PNG favicon it duplicated.
    expect(File.exist?(File.join(repo_root, "public/icon.svg"))).to be(false)
  end

  it "ships the desktop app icon at 1024 with the in-app icon at 512" do
    expect(png_dimensions("desktop/build/icon.png")).to eq([1024, 1024])
    expect(png_dimensions("desktop/assets/syrusIcon.png")).to eq([512, 512])
  end

  it "keeps the menu-bar template icon small and square" do
    width, height = png_dimensions("desktop/assets/syrusMenubarTemplate.png")
    expect(width).to eq(height)
    expect(width).to be_between(18, 64)
  end

  it "leaves the existing icon references intact" do
    layout = File.read(File.join(repo_root, "app/views/layouts/spa.html.erb"), encoding: "UTF-8")
    # Versioned (?v=N): public/ files are cached for a year, so rebranded
    # icons must change URL — see app/frontend/lib/brandIcon.ts.
    expect(layout).to match(%r{href="/icon\.png\?v=\d+"})
    expect(layout).not_to include("icon.svg")
    manifest = File.read(File.join(repo_root, "app/views/pwa/manifest.json.erb"), encoding: "UTF-8")
    expect(manifest).to include("/icon-192.png")
    expect(manifest).to include("/icon-512.png")
  end

  it "keeps the favicon's ?v= in sync with BRAND_ICON_VERSION" do
    # spa.html.erb is server-rendered ERB and can't import a TS module, so the
    # version there is a hand-copied literal; this spec is what actually keeps
    # them from drifting apart, since nothing in app/frontend imports the
    # constant anymore (the in-app mark is a theme-aware inline SVG now, not
    # this PNG — see app/frontend/components/SyrusBrand.tsx).
    brand_icon_ts = File.read(File.join(repo_root, "app/frontend/lib/brandIcon.ts"), encoding: "UTF-8")
    ts_version = brand_icon_ts[/BRAND_ICON_VERSION\s*=\s*(\d+)/, 1]
    expect(ts_version).not_to be_nil

    layout = File.read(File.join(repo_root, "app/views/layouts/spa.html.erb"), encoding: "UTF-8")
    layout_version = layout[%r{href="/icon\.png\?v=(\d+)"}, 1]
    expect(layout_version).to eq(ts_version)
  end
end
