require "rails_helper"
require Rails.root.join("config/retention_archive_storage")

RSpec.describe RetentionArchiveStorageConfig do
  FakeActiveStorageConfig = Struct.new(:service, keyword_init: true)
  FakeAppConfig = Struct.new(:active_storage, keyword_init: true)

  def app_config(primary_service)
    FakeAppConfig.new(active_storage: FakeActiveStorageConfig.new(service: primary_service))
  end

  it "falls back to the primary active_storage service when the env var is unset" do
    resolved = described_class.resolve(app_config(:minio), env: {})

    expect(resolved).to eq(:minio)
  end

  it "falls back to the primary active_storage service when the env var is blank" do
    resolved = described_class.resolve(app_config(:local), env: { "RETENTION_ARCHIVE_STORAGE_SERVICE" => "" })

    expect(resolved).to eq(:local)
  end

  it "overrides with the env var when present" do
    resolved = described_class.resolve(
      app_config(:minio),
      env: { "RETENTION_ARCHIVE_STORAGE_SERVICE" => "retention_archive_disk" }
    )

    expect(resolved).to eq(:retention_archive_disk)
  end

  it "always returns a symbol" do
    resolved = described_class.resolve(
      app_config("local"),
      env: { "RETENTION_ARCHIVE_STORAGE_SERVICE" => "retention_archive_s3" }
    )

    expect(resolved).to be_a(Symbol)
  end
end
