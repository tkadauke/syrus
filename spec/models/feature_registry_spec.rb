require "rails_helper"

RSpec.describe FeatureRegistry do
  it "returns typed boolean declarations for config/features.yml" do
    declarations = described_class.declarations

    expect(declarations).to all(have_attributes(type: :boolean))
    expect(declarations.map(&:slug)).to include(
      "terminal",
      "coding_mode",
      "video_walkthroughs",
      "local_mode",
      "agent_insights",
      WorkEngine::Gate::FEATURE_SLUG
    )
  end

  it "pins current feature flags as default-off" do
    defaults = described_class.declarations.index_by(&:slug).transform_values(&:default_enabled)

    expect(defaults).to include(
      "terminal" => false,
      "chat_polish" => false,
      "video_walkthroughs" => false,
      "coding_mode" => false,
      "performance_logging" => false,
      "local_mode" => false,
      "agent_insights" => false,
      WorkEngine::Gate::FEATURE_SLUG => false
    )
  end

  it "uses description as operational meaning unless explicitly declared" do
    declaration = described_class.declarations.find { |feature| feature.slug == "terminal" }

    expect(declaration.operational_meaning).to eq(declaration.description)
  end
end
