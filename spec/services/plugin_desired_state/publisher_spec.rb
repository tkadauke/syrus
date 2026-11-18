require "rails_helper"

RSpec.describe PluginDesiredState::Publisher do
  class RecordingPluginStorage
    attr_reader :writes

    def initialize(existing: [])
      @existing = existing
      @writes = []
    end

    def exist?(key) = @existing.include?(key)

    def upload(key, io, **)
      @writes << [ key, io.read ]
    end
  end

  let(:key) { OpenSSL::PKey.generate_key("ED25519") }
  let(:bytes) { "archive" }
  let(:digest) { Digest::SHA256.hexdigest(bytes) }
  let(:release) do
    PluginRelease.create!(
      name: "calendar", version: "2.0.0", content_digest: digest,
      source: "registry", trust_label: "verified", size_bytes: bytes.bytesize
    )
  end

  before do
    allow(described_class).to receive(:publish!)
    PluginInstallation.create!(plugin_name: release.name, plugin_release: release, roles: %w[web worker])
    allow(described_class).to receive(:publish!).and_call_original
  end

  it "increments revisions, renders the desired set, signs it, and writes the manifest last" do
    service = RecordingPluginStorage.new(existing: [ "plugins/artifacts/#{digest}" ])
    publisher = described_class.new(service: service, key: key)

    first = publisher.publish!
    second = publisher.publish!

    expect([ first[:revision], second[:revision] ]).to eq([ 1, 2 ])
    expect(second[:plugins].sole).to include(
      name: "calendar", version: "2.0.0", digest: digest, size: bytes.bytesize,
      roles: %w[web worker], fleet_quarantined: false
    )
    expect(service.writes.map(&:first)).to eq([
      described_class::SIGNATURE_KEY, described_class::MANIFEST_KEY,
      described_class::SIGNATURE_KEY, described_class::MANIFEST_KEY
    ])

    manifest_json = service.writes[-1][1]
    signature = Base64.strict_decode64(service.writes[-2][1])
    expect(key.verify(nil, signature, manifest_json)).to be(true)
    expect(key.verify(nil, signature, "#{manifest_json} ")).to be(false)
  end

  it "does not publish when a referenced artifact is absent" do
    service = RecordingPluginStorage.new

    expect { described_class.new(service: service, key: key).publish! }
      .to raise_error(described_class::MissingArtifact)
    expect(service.writes).to be_empty
    expect(PluginDesiredStateRevision.current).to eq(0)
  end
end
