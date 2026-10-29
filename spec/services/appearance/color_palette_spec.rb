require "rails_helper"
require Rails.root.join("db/seeds/themes")

RSpec.describe Appearance::ColorPalette do
  it "provides six families containing 72 named, valid colors" do
    expect(described_class.families.size).to eq(6)
    expect(described_class.entries.size).to eq(72)
    expect(described_class.entries.map { |entry| entry.fetch("name") }.uniq.size).to eq(72)
    expect(described_class.entries).to all(satisfy { |entry| described_class.valid_hex?(entry.fetch("hex")) })
  end

  it "uses the seeded light brand values for built-in themes" do
    seeded = Seeds::Themes::BASE_DEFINITIONS.to_h do |definition|
      [ definition.fetch(:name), definition.dig(:tokens, "light", "brand") ]
    end

    expect(described_class.theme_colors).to eq(seeded)
    expect(described_class.theme_colors).to include(
      "Terracotta" => "#b6492e", "Sand" => "#a97a4a", "Moss" => "#6f7d3c", "Slate" => "#46647d"
    )
  end

  it "never assigns two hexes to a name shared by themes and accents" do
    conflicts = described_class.entries.filter_map do |entry|
      theme_hex = described_class.theme_colors[entry.fetch("name")]
      [ entry.fetch("name"), entry.fetch("hex"), theme_hex ] if theme_hex && theme_hex != entry.fetch("hex")
    end

    expect(conflicts).to be_empty
  end

  it "matches the TypeScript OKLab distance expectations" do
    expect(described_class.color_distance("#0090FF", "#F5A524")).to be_within(1e-10).of(37.56643284875839)
    expect(described_class.color_distance("#E5484D", "#9B1C31")).to be_within(1e-10).of(17.7733899369609)
    expect { described_class.color_distance("blue", "#0090FF") }.to raise_error(ArgumentError, /#RRGGBB/)
  end

  it "finds the nearest library color" do
    expect(described_class.nearest_color("#E9B7AA")).to include("name" => "Blush", "hex" => "#FBCFD3")
  end

  it "assigns the next unused color from the shared default order" do
    expected = %w[#0090FF #F5A524 #9B1C31 #2B3A9E #6E56CF #C07C5A #8E7BA8 #A16207]
    expect(described_class.default_agent_order).to eq(expected)
    expect(described_class.next_default_color(%w[#0090ff #F5A524])).to eq("#9B1C31")
    expect(described_class.next_default_color(expected)).to be_nil
  end
end
