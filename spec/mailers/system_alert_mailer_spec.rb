require "rails_helper"

RSpec.describe SystemAlertMailer, type: :mailer do
  let(:payload) do
    {
      title: "Database unavailable",
      severity: "alarm",
      dismissal_key: "database:unavailable",
      message: "Restore the primary database.",
      action_steps: [ "Inspect the database host." ],
      cta: { text: "Open runbook", url: "https://example.test/runbook" },
      app_url: "https://example.test"
    }
  end

  it "translates fixed copy while preserving operational payload text" do
    mail = described_class.with(locale: "de").alarm(payload, to: [ "ops@example.test" ])

    expect(mail.subject).to eq("[Syrus-Alarm] Database unavailable")
    expect(mail.html_part.body.encoded).to include("Schweregrad:")
    expect(mail.html_part.body.encoded).to include("Handlungsschritte")
    expect(mail.html_part.body.encoded).to include("Syrus öffnen")
    expect(mail.html_part.body.encoded).to include("Restore the primary database.")
    expect(mail.html_part.body.encoded).to include("Open runbook")
    expect(mail.html_part.body.encoded).to include('<html lang="de">')
  end
end
