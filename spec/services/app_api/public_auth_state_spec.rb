require "rails_helper"

RSpec.describe AppApi::PublicAuthState do
  def payload(user: nil, invitation_token: nil)
    described_class.new(user: user, invitation_token: invitation_token).as_json
  end

  def invitation(**attrs)
    Invitation.create!({
      invited_by: attrs[:invited_by] || Factories.user,
      email_address: attrs[:email_address] || "guest@example.com"
    }.merge(attrs))
  end

  before do
    AppSetting.current.update!(signups_open: false)
  end

  it "points first-run visitors at first account creation" do
    expect(payload).to include(
      authenticated: false,
      first_signup: true,
      signups_open: false,
      valid_invitation: false,
      cta: {
        kind: "create_first_account",
        label: "Create first account",
        href: "/users/new"
      }
    )
  end

  it "points authenticated users at the dashboard even when an invitation token is present" do
    user = Factories.user
    invite = invitation(invited_by: user)

    expect(payload(user: user, invitation_token: invite.token)).to include(
      authenticated: true,
      valid_invitation: true,
      cta: {
        kind: "dashboard",
        label: "Open dashboard",
        href: "/dashboard/jobs?view=list"
      }
    )
  end

  it "points visitors with usable invitations at tokenized sign-up" do
    admin = Factories.user
    invite = invitation(invited_by: admin)

    expect(payload(invitation_token: invite.token)).to include(
      first_signup: false,
      signups_open: false,
      valid_invitation: true,
      cta: {
        kind: "accept_invitation",
        label: "Accept invitation",
        href: "/users/new?token=#{invite.token}"
      }
    )
  end

  it "escapes invitation tokens in the sign-up CTA" do
    admin = Factories.user
    invite = invitation(invited_by: admin)
    invite.update_column(:token, "token with/slash+plus?")

    expect(payload(invitation_token: invite.token).dig(:cta, :href))
      .to eq("/users/new?token=token+with%2Fslash%2Bplus%3F")
  end

  it "does not accept expired invitation tokens" do
    admin = Factories.user
    invite = invitation(invited_by: admin, expires_at: 1.minute.ago)

    expect(payload(invitation_token: invite.token)).to include(
      first_signup: false,
      valid_invitation: false,
      cta: {
        kind: "sign_in",
        label: "Sign in",
        href: "/session/new"
      }
    )
  end

  it "does not accept already accepted invitation tokens" do
    admin = Factories.user
    invite = invitation(invited_by: admin, accepted_at: Time.current)

    expect(payload(invitation_token: invite.token)).to include(
      valid_invitation: false,
      cta: {
        kind: "sign_in",
        label: "Sign in",
        href: "/session/new"
      }
    )
  end

  it "points visitors at open sign-up when signups are enabled" do
    Factories.user
    AppSetting.current.update!(signups_open: true)

    expect(payload).to include(
      first_signup: false,
      signups_open: true,
      cta: {
        kind: "sign_up",
        label: "Create account",
        href: "/users/new"
      }
    )
  end
end
