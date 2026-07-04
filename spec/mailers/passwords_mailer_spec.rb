require "rails_helper"

RSpec.describe PasswordsMailer, type: :mailer do
  it "renders password reset delivery details" do
    user = Factories.user(email_address: "user@example.com")

    mail = described_class.reset(user)

    expect(mail.subject).to eq("Reset your password")
    expect(mail.to).to eq([ "user@example.com" ])

    expect(mail.text_part.body.encoded).to include("You can reset your password on")
    expect(mail.text_part.body.encoded).to include("/passwords/")
    expect(mail.text_part.body.encoded).to include("This link will expire in")

    expect(mail.html_part.body.encoded).to include("You can reset your password on")
    expect(mail.html_part.body.encoded).to include("this password reset page")
    expect(mail.html_part.body.encoded).to include("This link will expire in")
  end

  it "resolves the subject from the locale file" do
    I18n.with_locale(:de) do
      expect(described_class.reset(Factories.user).subject).to eq("Passwort zurücksetzen")
    end
  end
end
