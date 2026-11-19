require "rails_helper"

RSpec.describe LocalBackups::Manifest do
  def manifest_data
    {
      manifest_version: 1, backup_id: "123e4567-e89b-42d3-a456-426614174000", installation_id: "installation",
      completed_at: "2026-11-19T00:00:00Z", validated_at: "2026-11-19T00:01:00Z",
      database: { adapter: "sqlite3" }, storage: { logical_bytes: 10, stored_bytes: 8, blob_count: 1 },
      encryption_fingerprints: { primary: "sha256:#{'1' * 64}" }, artifact: { checksum_algorithm: "sha256", checksum: "a" * 64 },
      validation: { result: "valid" }
    }
  end

  it "writes and reads a v1 manifest without changing its fingerprint" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("manifest.json")
      written = described_class.new(manifest_data)
      written.write_once(path)

      expect(described_class.read(path).fingerprint).to eq(written.fingerprint)
    end
  end

  it "refuses to overwrite an immutable manifest" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("manifest.json")
      described_class.new(manifest_data).write_once(path)
      expect { described_class.new(manifest_data).write_once(path) }.to raise_error(described_class::Invalid, /already exists/)
    end
  end

  it "rejects unknown major versions and unsealed manifests" do
    expect { described_class.new(manifest_data.merge(manifest_version: 2)).validate! }.to raise_error(described_class::UnknownVersion)
    expect { described_class.new(manifest_data.deep_merge(validation: { result: "failed" })).validate! }.to raise_error(described_class::Invalid, /not sealed/)
  end
end
