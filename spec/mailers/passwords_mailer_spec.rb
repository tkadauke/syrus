require "rails_helper"

RSpec.describe PasswordsMailer, type: :mailer do
  it "renders password reset delivery details" do
    user = Factories.user(email_address: "user@example.com")

    mail = described_class.with(locale: user.locale).reset(user)

    expect(mail.subject).to eq("Reset your password")
    expect(mail.to).to eq([ "user@example.com" ])

    expect(mail.text_part.body.encoded).to include("You can reset your password on")
    expect(mail.text_part.body.encoded).to include("/passwords/")
    expect(mail.text_part.body.encoded).to include("This link will expire in")

    expect(mail.html_part.body.encoded).to include("You can reset your password on")
    expect(mail.html_part.body.encoded).to include("this password reset page")
    expect(mail.html_part.body.encoded).to include("This link will expire in")
    expect(mail.html_part.body.encoded).to include('<html lang="en">')
  end

  it "preserves the parameterized recipient locale through delayed delivery" do
    user = Factories.user(locale: "de")
    described_class.with(locale: user.locale).reset(user).deliver_later

    I18n.with_locale(:la) do
      perform_enqueued_jobs
    end

    mail = ActionMailer::Base.deliveries.last
    expect(mail.subject).to eq("Passwort zurücksetzen")
    expect(mail.html_part.body.encoded).to include("Du kannst dein Passwort")
    expect(mail.html_part.body.encoded).to include('<html lang="de">')
  end

  it "falls back safely when the parameterized locale is unsupported" do
    mail = described_class.with(locale: "unsupported").reset(Factories.user)

    expect(mail.subject).to eq("Reset your password")
    expect(mail.html_part.body.encoded).to include('<html lang="en">')
  end
end
