require "rails_helper"

RSpec.describe FilterUsage, type: :model do
  let(:user) { Factories.user }

  def valid_attrs(overrides = {})
    {
      user: user,
      surface: "dashboard",
      subject: SmartFolder::SUBJECT_TYPES.first,
      fingerprint: "fp-abc123",
      filter_node: { "type" => "status", "value" => "open" },
      label: "Open jobs",
      use_count: 0,
      last_used_at: Time.current
    }.merge(overrides)
  end

  it "is valid with all required attributes" do
    expect(described_class.new(valid_attrs)).to be_valid
  end

  it "requires surface" do
    expect(described_class.new(valid_attrs(surface: nil))).not_to be_valid
  end

  it "rejects unknown surfaces" do
    expect(described_class.new(valid_attrs(surface: "admin"))).not_to be_valid
  end

  it "accepts all known surfaces" do
    FilterUsage::SURFACES.each do |surface|
      expect(described_class.new(valid_attrs(surface: surface))).to be_valid
    end
  end

  it "requires subject" do
    expect(described_class.new(valid_attrs(subject: nil))).not_to be_valid
  end

  it "rejects unknown subjects" do
    expect(described_class.new(valid_attrs(subject: "unknown_type"))).not_to be_valid
  end

  it "accepts all known subject types" do
    SmartFolder::SUBJECT_TYPES.each do |type|
      expect(described_class.new(valid_attrs(subject: type, fingerprint: "fp-#{type}"))).to be_valid
    end
  end

  it "requires fingerprint" do
    expect(described_class.new(valid_attrs(fingerprint: nil))).not_to be_valid
  end

  it "requires filter_node" do
    expect(described_class.new(valid_attrs(filter_node: nil))).not_to be_valid
  end

  it "requires label" do
    expect(described_class.new(valid_attrs(label: nil))).not_to be_valid
    expect(described_class.new(valid_attrs(label: ""))).not_to be_valid
  end

  it "requires use_count to be a non-negative integer" do
    expect(described_class.new(valid_attrs(use_count: -1))).not_to be_valid
    expect(described_class.new(valid_attrs(use_count: 0))).to be_valid
    expect(described_class.new(valid_attrs(use_count: 10))).to be_valid
  end

  it "enforces uniqueness of fingerprint per user, surface, and subject" do
    described_class.create!(valid_attrs)

    duplicate = described_class.new(valid_attrs)
    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:fingerprint]).to be_present
  end

  it "allows the same fingerprint for different users" do
    other_user = Factories.user
    described_class.create!(valid_attrs)

    second = described_class.new(valid_attrs(user: other_user))
    expect(second).to be_valid
  end

  it "allows the same fingerprint for a different subject within the same user and surface" do
    described_class.create!(valid_attrs)

    alt_subject = SmartFolder::SUBJECT_TYPES.last
    second = described_class.new(valid_attrs(subject: alt_subject))
    expect(second).to be_valid
  end
end
