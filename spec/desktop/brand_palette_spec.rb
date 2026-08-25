# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/design_tokens/terracotta_theme"

# The product accent is the terracotta of the winged-stylus brand mark.
# config/design_tokens/terracotta.json is the single shared source: the web
# app's config/tailwind.config.js requires it directly, and
# bin/generate-brand-tokens renders the equivalent @theme partial consumed
# by desktop/src/styles.css. This spec validates both consumers against
# that shared source (not a third hardcoded copy of the hex literals) and
# fails if either drifts from what regenerating would produce.
RSpec.describe "brand palette" do
  let(:repo_root) { File.expand_path("../..", __dir__) }

  def read(relative_path)
    File.read(File.join(repo_root, relative_path), encoding: "UTF-8")
  end

  let(:web_tailwind) { read("config/tailwind.config.js") }
  let(:desktop_css) { read("desktop/src/styles.css") }
  let(:desktop_generated_css) { read("desktop/src/styles/brand-tokens.generated.css") }
  let(:brand_scale) { DesignTokens::TerracottaTheme.scale }

  it "requires the shared terracotta JSON source in the web app instead of a hand-copied literal" do
    expect(web_tailwind).to match(%r{require\(["']\./design_tokens/terracotta\.json["']\)})
    expect(web_tailwind).to match(/terracotta,\s*blue: terracotta/)
  end

  it "imports the generated brand tokens partial in the desktop @theme block" do
    expect(desktop_css).to include('@import "./styles/brand-tokens.generated.css"')
  end

  it "matches exactly what regenerating from the shared source would produce" do
    expect(desktop_generated_css).to eq(DesignTokens::TerracottaTheme.desktop_css),
      "desktop/src/styles/brand-tokens.generated.css is stale — run bin/generate-brand-tokens"
  end

  it "mirrors the identical scale in the generated desktop CSS" do
    brand_scale.each do |step, hex|
      expect(desktop_generated_css).to include("--color-terracotta-#{step}: #{hex};")
      expect(desktop_generated_css).to include("--color-blue-#{step}: #{hex};")
    end
  end

  it "keeps raw default-Tailwind blues out of the generated desktop CSS" do
    default_blues = %w[#2563eb #1d4ed8 #3b82f6 #60a5fa #93c5fd #bfdbfe #dbeafe #eff6ff #1e40af #1e3a8a]
    default_blues.each do |hex|
      expect(desktop_generated_css.downcase).not_to include(hex), "found default blue #{hex} in the generated desktop CSS"
    end
  end

  it "anchors the 600 step to the brand mark's terracotta" do
    expect(brand_scale.fetch("600")).to eq("#b6492e")
  end
end
