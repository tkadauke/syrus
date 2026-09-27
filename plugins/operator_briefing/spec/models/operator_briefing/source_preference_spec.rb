require "rails_helper"

RSpec.describe OperatorBriefing::SourcePreference, type: :model do
  let(:user) { Factories.user }

  it "seeds every default source as confirmed and enabled" do
    described_class.seed_for_user!(user)

    preferences = described_class.where(user: user)
    expect(preferences.pluck(:source_key)).to match_array(described_class::SOURCE_KEYS)
    expect(preferences).to all(be_enabled)
    expect(preferences).to all(satisfy { |preference| preference.confirmed_at.present? })
  end

  it "keeps pending AI suggestions separate from the effective preference" do
    described_class.seed_for_user!(user)
    suggestion = described_class.suggest!(user: user, source_key: "spend", enabled: false)

    effective = described_class.effective_for_user(user).fetch("spend")

    expect(effective).to be_enabled
    expect(suggestion.confirmed_at).to be_nil
    expect(described_class.pending_for_user(user)).to include(suggestion)
  end

  it "preserves AI suggestion provenance when confirmed" do
    suggestion = described_class.suggest!(user: user, source_key: "spend", enabled: false)

    suggestion.confirm!

    expect(suggestion).to have_attributes(suggested_by: "ai")
    expect(suggestion.confirmed_at).to be_present
  end

  it "uses the latest confirmed row as the effective preference" do
    described_class.seed_for_user!(user)
    described_class.create!(
      user: user,
      source_key: "spend",
      enabled: false,
      weight: 1.0,
      suggested_by: "user",
      confirmed_at: Time.current
    )

    expect(described_class.effective_for_user(user).fetch("spend")).not_to be_enabled
  end
end
