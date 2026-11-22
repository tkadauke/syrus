require "rails_helper"

RSpec.describe PluginRelease do
  it "accepts the supported release metadata and rejects unknown sources" do
    release = described_class.new(name: "weather", version: "1.2.3", content_digest: "a" * 64,
      source: "unknown", trust_label: "verified", size_bytes: 12)

    expect(release).not_to be_valid
    expect(release.errors[:source]).to be_present
  end

  it "keeps bundled releases artifact-free" do
    release = described_class.create!(name: "weather", version: "1.2.3", content_digest: "a" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0)

    expect(release.archive).not_to be_attached
  end

  it "keeps artifact identity immutable after the archive is verified" do
    body = "plugin archive"
    release = described_class.create!(name: "weather", version: "1.2.3", content_digest: Digest::SHA256.hexdigest(body),
      source: "upload", trust_label: "unsigned_local", size_bytes: body.bytesize)
    PluginArtifacts.store!(release, StringIO.new(body))

    {
      name: "weather-pro",
      version: "2.0.0",
      content_digest: "b" * 64,
      source: "registry",
      size_bytes: body.bytesize + 1
    }.each do |attribute, value|
      expect(release.update(attribute => value)).to be(false)
      expect(release.errors[:base]).to include("plugin release artifact identity is immutable after storage or selection")
      release.reload
    end
  end

  it "keeps artifact identity immutable after a release without an archive is selected" do
    release = described_class.create!(name: "weather", version: "1.2.3", content_digest: "a" * 64,
      source: "bundled", trust_label: "official", size_bytes: 0)
    allow(PluginDesiredState::Publisher).to receive(:publish!)
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release)

    expect(release.update(version: "2.0.0")).to be(false)
    expect(release.errors[:base]).to include("plugin release artifact identity is immutable after storage or selection")
  end
end
