require "rails_helper"

RSpec.describe Passkey do
  let(:user) { Factories.user }

  def build_passkey(**attrs)
    described_class.new({
      user: user,
      external_id: SecureRandom.urlsafe_base64(32),
      public_key: SecureRandom.base64(64)
    }.merge(attrs))
  end

  it "is valid with required attributes" do
    passkey = build_passkey
    expect(passkey).to be_valid
  end

  it "requires external_id" do
    passkey = build_passkey(external_id: nil)
    expect(passkey).not_to be_valid
    expect(passkey.errors[:external_id]).to be_present
  end

  it "requires public_key" do
    passkey = build_passkey(public_key: nil)
    expect(passkey).not_to be_valid
    expect(passkey.errors[:public_key]).to be_present
  end

  describe ".find_by_external_id" do
    it "returns the passkey with the matching external_id" do
      passkey = build_passkey
      passkey.save!

      result = described_class.find_by_external_id(passkey.external_id)
      expect(result).to eq(passkey)
    end

    it "returns nil when no passkey matches" do
      expect(described_class.find_by_external_id("nonexistent")).to be_nil
    end
  end
end
