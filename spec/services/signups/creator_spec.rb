require "rails_helper"

RSpec.describe Signups::Creator do
  it "creates a user and consumes a usable invitation atomically" do
    admin = Factories.user
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")

    result = described_class.call(
      attributes: { email_address: "guest@example.com", password: "supersecret" },
      invitation: invitation
    )

    expect(result).to be_created
    expect(result.user).to be_persisted
    expect(invitation.reload).to be_accepted
  end

  it "rolls back user creation when invitation consumption fails" do
    admin = Factories.user
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")
    allow(invitation).to receive(:accept!).and_raise(ActiveRecord::RecordInvalid)

    expect {
      described_class.call(
        attributes: { email_address: "guest@example.com", password: "supersecret" },
        invitation: invitation
      )
    }.to raise_error(ActiveRecord::RecordInvalid)

    expect(User.where(email_address: "guest@example.com")).not_to exist
  end

  it "rejects an invitation that became unusable before creation" do
    admin = Factories.user
    invitation = Invitation.create!(invited_by: admin, email_address: "guest@example.com")
    invitation.accept!

    result = described_class.call(
      attributes: { email_address: "guest@example.com", password: "supersecret" },
      invitation: invitation
    )

    expect(result).to be_forbidden
    expect(result.user).not_to be_persisted
  end

  it "returns an invalid result when a concurrent signup wins the unique email race" do
    AppSetting.current.update!(signups_open: true)
    user = instance_double(User, save: nil, errors: ActiveModel::Errors.new(User.new))
    allow(User).to receive(:new).and_return(user)
    allow(user).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

    result = described_class.call(
      attributes: { email_address: "guest@example.com", password: "supersecret" }
    )

    expect(result.status).to eq(:invalid)
    expect(result.user.errors[:email_address]).to include("has already been taken")
  end
end
