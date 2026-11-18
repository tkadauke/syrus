require "rails_helper"

RSpec.describe PluginRelease do
  it "accepts only declared release sources" do
    release = described_class.new(
      name: "sample", version: "1", content_digest: "a" * 64,
      source: "unknown", trust_label: "operator", size_bytes: 1
    )

    expect(release).not_to be_valid
    expect(release.errors[:source]).to be_present
  end
end
