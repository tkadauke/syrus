require "rails_helper"

RSpec.describe PluginDesiredState::Publisher do
  class RecordingPluginManifestStorage
    attr_reader :writes

    def initialize
      @objects = {}
      @writes = []
    end

    def upload(key, io, **)
      @writes << key
      @objects[key] = io.read
    end

    def download(key) = @objects.fetch(key)
  end

  let(:service) { RecordingPluginManifestStorage.new }
  let(:body) { "archive" }
  let(:digest) { Digest::SHA256.hexdigest(body) }
  let!(:release) do
    PluginRelease.create!(name: "weather", version: "2.0.0", content_digest: digest,
      source: "upload", trust_label: "unsigned_local", size_bytes: body.bytesize)
  end

  before do
    allow(described_class).to receive(:publish!)
    PluginArtifacts.store!(release, StringIO.new(body))
    PluginInstallation.create!(plugin_name: "weather", plugin_release: release, roles: %w[web worker], fleet_quarantined: true)
    allow(described_class).to receive(:publish!).and_call_original
  end

  it "increments the revision and publishes a signed manifest last" do
    first = JSON.parse(described_class.publish!(service:))
    second = JSON.parse(described_class.publish!(service:))

    expect(second.fetch("revision")).to eq(first.fetch("revision") + 1)
    expect(second.fetch("plugins").sole).to include(
      "name" => "weather", "version" => "2.0.0", "digest" => digest, "size" => body.bytesize,
      "roles" => %w[web worker], "fleet_quarantined" => true
    )
    expect(service.writes.last(2)).to eq([
      PluginDesiredState::Publisher::SIGNATURE_KEY,
      PluginDesiredState::Publisher::MANIFEST_KEY
    ])
  end

  it "produces a signature that verifies and rejects tampering" do
    manifest = described_class.publish!(service:)
    signature = Base64.strict_decode64(service.download(described_class::SIGNATURE_KEY))
    verify_key = Ed25519::VerifyKey.new(Base64.strict_decode64(PluginDesiredState::SigningKey.current.public_key))

    expect { verify_key.verify(signature, manifest) }.not_to raise_error
    expect { verify_key.verify(signature, "#{manifest} ") }.to raise_error(Ed25519::VerifyError)
  end
end
