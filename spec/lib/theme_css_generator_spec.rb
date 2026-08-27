require "rails_helper"
require Rails.root.join("lib/theme_css_generator")
require Rails.root.join("db/seeds/themes")

RSpec.describe ThemeCssGenerator do
  def unsaved_theme(definition)
    Theme.new(slug: definition.fetch(:slug), name: definition.fetch(:name), tokens: definition.fetch(:tokens))
  end

  describe ".css_for" do
    it "emits a :root[data-theme] block and a .dark variant per theme, with all 13 tokens" do
      theme = unsaved_theme(Seeds::Themes::DEFINITIONS.first)
      css = described_class.css_for([ theme ])

      expect(css).to include(%(:root[data-theme="#{theme.slug}"] {))
      expect(css).to include(%(:root[data-theme="#{theme.slug}"].dark {))
      Theme::TOKEN_KEYS.each do |key|
        expect(css).to include("--color-#{key}: #{theme.tokens.fetch('light').fetch(key)};")
        expect(css).to include("--color-#{key}: #{theme.tokens.fetch('dark').fetch(key)};")
      end
    end

    it "includes a do-not-edit generated file header" do
      css = described_class.css_for([])
      expect(css).to include("GENERATED FILE. Do not edit by hand.")
      expect(css).to include("bin/generate-theme-css")
    end

    it "renders themes in the order given" do
      themes = Seeds::Themes::DEFINITIONS.map { |d| unsaved_theme(d) }
      css = described_class.css_for(themes)

      positions = themes.map { |t| css.index(%(:root[data-theme="#{t.slug}"] {)) }
      expect(positions).to eq(positions.sort)
    end
  end

  describe "the checked-in generated file" do
    it "matches exactly what regenerating from db/seeds/themes.rb would produce" do
      themes = Seeds::Themes::DEFINITIONS.sort_by { |d| d.fetch(:slug) }.map { |d| unsaved_theme(d) }
      expected = described_class.css_for(themes)

      actual = File.read(ThemeCssGenerator::OUTPUT_PATH)
      expect(actual).to eq(expected),
        "app/assets/tailwind/generated/themes.generated.css is stale — run bin/generate-theme-css"
    end
  end
end
