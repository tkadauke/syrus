require "rails_helper"

RSpec.describe PluginArtifacts do
  let(:body) { "plugin archive bytes" }
  let(:digest) { Digest::SHA256.hexdigest(body) }
  let(:release) do
    PluginRelease.create!(name: "weather", version: "1.2.3", content_digest: digest,
      source: "upload", trust_label: "unsigned_local", size_bytes: body.bytesize)
  end

  it "stores a verified artifact at its content-addressed key" do
    described_class.store!(release, StringIO.new(body))

    expect(release.archive.blob.key).to eq("plugins/artifacts/#{digest}")
    expect(release.archive.download).to eq(body)
  end

  it "rejects bytes that do not match the declared digest" do
    expect { described_class.store!(release, StringIO.new("tampered")) }
      .to raise_error(PluginArtifacts::DigestMismatch, /digest/)
    expect(release.archive).not_to be_attached
  end

  it "works with the local-volume disk service used by SQLite installations" do
    service = ActiveStorage::Blob.services.fetch(:local_volume)
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)

    described_class.store!(release, StringIO.new(body))

    expect(service.download("plugins/artifacts/#{digest}")).to eq(body)
  ensure
    service&.delete("plugins/artifacts/#{digest}")
  end
end
