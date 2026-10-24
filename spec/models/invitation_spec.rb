require "rails_helper"

RSpec.describe Invitation do
  let(:admin) { Factories.user }

  it "snapshots the inviter locale" do
    inviter = Factories.user(locale: "de")
    invitation = described_class.create!(invited_by: inviter, email_address: "guest@example.com")

    inviter.update!(locale: "la")

    expect(invitation.reload.locale).to eq("de")
  end

  it "rejects an explicitly unsupported locale when creating an invitation" do
    expect {
      described_class.create!(invited_by: admin, email_address: "guest@example.com", locale: "fr")
    }.to raise_error(ActiveRecord::RecordInvalid, /Locale/)
  end

  it "auto-generates a token and sets a default expiry on create" do
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")
    expect(invitation.token).to be_present
    expect(invitation.expires_at).to be > Time.current
  end

  it "is usable while pending and not expired" do
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")
    expect(invitation).to be_usable
  end

  it "is no longer usable after acceptance" do
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")
    invitation.accept!
    expect(invitation).to be_accepted
    expect(invitation).not_to be_usable
  end

  it "is not usable once expired" do
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com", expires_at: 1.minute.from_now)
    travel 2.minutes do
      expect(invitation.reload).to be_expired
      expect(invitation.reload).not_to be_usable
    end
  end

  it "normalizes email_address" do
    invitation = Invitation.create!(invited_by: admin, email_address: "  Guest@Example.com ")
    expect(invitation.email_address).to eq("guest@example.com")
  end

  it "scopes pending to non-accepted, non-expired" do
    pending = Invitation.create!(invited_by: admin, email_address: "p@example.com")
    accepted = Invitation.create!(invited_by: admin, email_address: "a@example.com")
    accepted.accept!
    expired = Invitation.create!(invited_by: admin, email_address: "e@example.com", expires_at: 1.second.ago)
    expect(Invitation.pending).to contain_exactly(pending)
  end
end
