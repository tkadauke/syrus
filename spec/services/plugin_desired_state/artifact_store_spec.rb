require "rails_helper"

RSpec.describe PluginDesiredState::ArtifactStore do
  let(:bytes) { "plugin archive bytes" }
  let(:digest) { Digest::SHA256.hexdigest(bytes) }
  let(:release) do
    PluginRelease.create!(
      name: "weather", version: "1.2.3", content_digest: digest,
      source: "upload", trust_label: "operator", size_bytes: bytes.bytesize
    )
  end

  it "stores a verified archive at its content-addressed key" do
    release.store_archive!(StringIO.new(bytes))

    expect(release.archive).to be_attached
    expect(release.archive.blob.key).to eq("plugins/artifacts/#{digest}")
    expect(release.archive.download).to eq(bytes)
  end

  it "rejects bytes that do not match the recorded digest" do
    expect { release.store_archive!(StringIO.new("tampered")) }
      .to raise_error(described_class::DigestMismatch, /expected #{digest}/)
    expect(release.archive).not_to be_attached
  end

  it "works with the local-volume disk service" do
    service = ActiveStorage::Service.configure(:local_volume, Rails.configuration.active_storage.service_configurations)
    allow(ActiveStorage::Blob).to receive(:service).and_return(service)

    described_class.new(release, service: service).store!(StringIO.new(bytes))

    expect(service.download("plugins/artifacts/#{digest}")).to eq(bytes)
  ensure
    service&.delete("plugins/artifacts/#{digest}")
  end
end
