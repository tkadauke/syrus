require "rails_helper"

RSpec.describe RetentionArchive, type: :model do
  def upload(filename: "archive.json.gz", content_type: "application/gzip", content: "archived-rows")
    Rack::Test::UploadedFile.new(
      StringIO.new(content),
      content_type,
      original_filename: filename
    )
  end

  def valid_attributes(overrides = {})
    {
      retention_key: "provider_session",
      pruned_before: 30.days.ago,
      row_count: 42,
      byte_size: 1024
    }.merge(overrides)
  end

  it "is valid with valid attributes" do
    archive = described_class.new(valid_attributes)

    expect(archive).to be_valid
  end

  it "requires a retention_key" do
    archive = described_class.new(valid_attributes(retention_key: nil))

    expect(archive).not_to be_valid
    expect(archive.errors[:retention_key]).to include("can't be blank")
  end

  it "requires retention_key to match a RetentionPolicyRegistry key" do
    archive = described_class.new(valid_attributes(retention_key: "not_a_real_retention_key"))

    expect(archive).not_to be_valid
    expect(archive.errors[:retention_key]).to include("is not included in the list")
  end

  it "accepts every key registered in RetentionPolicyRegistry" do
    RetentionPolicyRegistry.definitions.each do |definition|
      archive = described_class.new(valid_attributes(retention_key: definition.key.to_s))

      expect(archive).to be_valid, "expected #{definition.key} to be a valid retention_key"
    end
  end

  it "requires pruned_before" do
    archive = described_class.new(valid_attributes(pruned_before: nil))

    expect(archive).not_to be_valid
    expect(archive.errors[:pruned_before]).to include("can't be blank")
  end

  it "requires row_count to be a non-negative integer" do
    archive = described_class.new(valid_attributes(row_count: -1))

    expect(archive).not_to be_valid
    expect(archive.errors[:row_count]).to include("must be greater than or equal to 0")
  end

  it "requires byte_size to be a non-negative integer" do
    archive = described_class.new(valid_attributes(byte_size: -1))

    expect(archive).not_to be_valid
    expect(archive.errors[:byte_size]).to include("must be greater than or equal to 0")
  end

  it "attaches archive_file against the configured test-env storage service" do
    archive = described_class.create!(valid_attributes)
    archive.archive_file.attach(upload)

    expect(archive.archive_file).to be_attached
    expect(archive.archive_file.filename.to_s).to eq("archive.json.gz")
    expect(archive.archive_file.service_name.to_sym).to eq(Rails.application.config.retention_archive_storage_service)
  end

  describe ".for_retention_key" do
    it "scopes to a single retention_key" do
      matching = described_class.create!(valid_attributes)
      other = described_class.create!(valid_attributes(retention_key: "spawned_process"))

      expect(described_class.for_retention_key("provider_session")).to include(matching)
      expect(described_class.for_retention_key("provider_session")).not_to include(other)
    end
  end

  describe ".newest_first" do
    it "orders by pruned_before descending" do
      older = described_class.create!(valid_attributes(pruned_before: 60.days.ago))
      newer = described_class.create!(valid_attributes(pruned_before: 1.day.ago))

      expect(described_class.newest_first).to eq([ newer, older ])
    end
  end
end
