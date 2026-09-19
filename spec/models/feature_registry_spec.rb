require "rails_helper"

RSpec.describe FeatureRegistry do
  it "returns typed boolean declarations for config/features.yml" do
    declarations = described_class.declarations

    expect(declarations).to all(have_attributes(type: :boolean))
    expect(declarations.map(&:slug)).to include(
      "coding_mode",
      "local_mode",
      "landing_validation_prefetch"
    )
    expect(declarations.map(&:slug)).not_to include("visual_review")
  end

  it "pins current feature flags as default-off" do
    defaults = described_class.declarations.index_by(&:slug).transform_values(&:default_enabled)

    expect(defaults).to include(
      "performance_logging" => false,
      "landing_validation_prefetch" => false,
      "local_mode" => false,
      "persistent_mcp_sidecar" => false
    )
  end

  it "pins coding_mode as default-on" do
    defaults = described_class.declarations.index_by(&:slug).transform_values(&:default_enabled)

    expect(defaults).to include(
      "coding_mode" => true
    )
  end

  it "uses description as operational meaning unless explicitly declared" do
    declaration = described_class.declarations.find { |feature| feature.operational_meaning.blank? } ||
                  described_class.declarations.first

    expect(declaration.operational_meaning).to eq(declaration.description)
  end
end
