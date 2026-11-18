require "rails_helper"

RSpec.describe PluginRelease do
  it "accepts the supported release metadata and rejects unknown sources" do
    release = described_class.new(name: "weather", version: "1.2.3", content_digest: "a" * 64,
      source: "unknown", trust_label: "reviewed", size_bytes: 12)

    expect(release).not_to be_valid
    expect(release.errors[:source]).to be_present
  end

  it "keeps bundled releases artifact-free" do
    release = described_class.create!(name: "weather", version: "1.2.3", content_digest: "a" * 64,
      source: "bundled", trust_label: "bundled", size_bytes: 0)

    expect(release.archive).not_to be_attached
  end
end
