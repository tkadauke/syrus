require "rails_helper"

RSpec.describe InvitationMailer, type: :mailer do
  around do |example|
    previous_from = ENV["SYRUS_MAILER_FROM"]
    ENV["SYRUS_MAILER_FROM"] = "Syrus Invitations <invites@example.com>"
    example.run
  ensure
    previous_from.nil? ? ENV.delete("SYRUS_MAILER_FROM") : ENV["SYRUS_MAILER_FROM"] = previous_from
  end

  it "renders invitation delivery details" do
    inviter = Factories.user(first_name: "Ada", last_name: "Lovelace")
    invitation = Invitation.create!(
      invited_by: inviter,
      email_address: "guest@example.com",
      expires_at: Time.zone.local(2026, 6, 16, 12, 0, 0)
    )

    mail = described_class.invite(invitation)

    expect(mail.subject).to eq("You're invited to Syrus")
    expect(mail.to).to eq([ "guest@example.com" ])
    expect(mail.from).to eq([ "invites@example.com" ])
    expect(mail[:from].display_names).to eq([ "Syrus Invitations" ])

    expect(mail.text_part.body.encoded).to include("Ada Lovelace invited you to join Syrus.")
    expect(mail.text_part.body.encoded).to include("http://example.com/users/new?token=#{invitation.token}")
    expect(mail.text_part.body.encoded).to include("This invitation expires on")

    expect(mail.html_part.body.encoded).to include("Ada Lovelace invited you to join Syrus.")
    expect(mail.html_part.body.encoded).to include("http://example.com/users/new?token=#{invitation.token}")
    expect(mail.html_part.body.encoded).to include("This invitation expires on")
  end
end
