require "rails_helper"

RSpec.describe SyrusBrowser::ImageDiffRenderer do
  it "declares the expected artifact_type" do
    expect(described_class.artifact_type).to eq("visual_review_screenshot")
  end

  it "declares the expected renderer_type" do
    expect(described_class.renderer_type).to eq(:image_diff)
  end

  it "includes Syrus::Plugin::ArtifactRenderer" do
    expect(described_class.ancestors).to include(Syrus::Plugin::ArtifactRenderer)
  end
end
