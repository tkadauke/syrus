require "rails_helper"

RSpec.describe Appearance::ColorPalette do
  it "provides 64 stable, unique palette keys" do
    expect(described_class.entries.size).to eq(64)
    expect(described_class.keys.uniq.size).to eq(64)
    expect(described_class.entries).to all(include("key", "label", "light", "dark"))
  end

  it "keeps chat text at WCAG AA contrast in both themes" do
    failures = described_class.entries.flat_map do |entry|
      %w[light dark].filter_map do |mode|
        ratio = ColorContrast.ratio(described_class.text_colors.fetch(mode), entry.fetch(mode))
        "#{entry.fetch('key')} #{mode}: #{ratio.round(2)}" if ratio < ColorContrast::AA_NORMAL_TEXT_RATIO
      end
    end

    expect(failures).to be_empty, failures.join("\n")
  end

  it "chooses a deterministic default from a normalized handle" do
    expect(described_class.default_key("Syrus")).to eq("cyan-soft")
    expect(described_class.default_key("Syrus")).to eq(described_class.default_key("syrus"))
    expect(described_class.keys).to include(described_class.default_key("another-handle"))
  end
end
