require "rails_helper"

RSpec.describe LocalBackups::Manifest do
  let(:payload) do
    {
      backup_id: SecureRandom.uuid, completed_at: Time.current.iso8601,
      artifact: { logical_bytes: 10, stored_bytes: 8, blob_count: 1 },
      checksum: { algorithm: "sha256", value: "a" * 64 }, future_field: true
    }
  end

  it "writes an immutable v1 manifest and tolerates additive fields" do
    Dir.mktmpdir do |directory|
      path = described_class.write(directory, payload)
      expect(described_class.read(path).attributes).to include("manifest_version" => "1.0", "future_field" => true)
      expect { described_class.write(directory, payload) }.to raise_error(Errno::EEXIST)
    end
  end

  it "rejects an unknown major version" do
    Dir.mktmpdir do |directory|
      path = Pathname.new(directory).join("manifest.json")
      path.write(JSON.generate(payload.deep_stringify_keys.merge("manifest_version" => "2.0")))
      expect { described_class.read(path) }.to raise_error(described_class::UnsupportedVersion)
    end
  end
end
