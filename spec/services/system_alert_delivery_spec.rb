require "rails_helper"

RSpec.describe SystemAlertDelivery do
  def with_env(vars)
    old_values = vars.keys.to_h { |key| [ key, ENV[key] ] }
    vars.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def alert(severity: :alarm, dismissal_key: "codex_usage:1:exhausted")
    SystemAlerts::Alert.new(
      id: "codex_usage:1",
      dismissal_key: dismissal_key,
      severity: severity,
      title: "Codex usage limit has been reached.",
      message: "Codex reports <strong>0%</strong> remaining.",
      action_steps: [ "Pause Codex-backed automation." ],
      cta: { text: "Open agent settings", path: "/settings/agent" }
    )
  end

  it "delivers one webhook notification per alarm dismissal key" do
    stub = stub_request(:post, "https://alerts.example.test/syrus")
      .to_return(status: 204, body: "")

    with_env(
      "SYRUS_ALERT_WEBHOOK_URL" => "https://alerts.example.test/syrus",
      "SYRUS_ALERT_EMAIL_TO" => nil,
      "SYRUS_APP_HOST" => "syrus.example.test",
      "SYRUS_ASSUME_SSL" => "true"
    ) do
      2.times { described_class.deliver([ alert ]) }
    end

    expect(stub).to have_been_requested.once
    notification = SystemAlertNotification.sole
    expect(notification).to have_attributes(
      dismissal_key: "codex_usage:1:exhausted",
      alert_id: "codex_usage:1",
      severity: "alarm"
    )
    expect(notification.delivered_at).to be_present
    expect(notification.payload).to include(
      "title" => "Codex usage limit has been reached.",
      "message" => "Codex reports 0% remaining."
    )
  end

  it "ignores non-alarm alerts" do
    stub_request(:post, "https://alerts.example.test/syrus")

    with_env("SYRUS_ALERT_WEBHOOK_URL" => "https://alerts.example.test/syrus") do
      described_class.deliver([ alert(severity: :warn, dismissal_key: "codex_usage:1:warning") ])
    end

    expect(WebMock).not_to have_requested(:post, "https://alerts.example.test/syrus")
    expect(SystemAlertNotification.count).to eq(0)
  end

  it "can deliver to configured email recipients" do
    with_env("SYRUS_ALERT_WEBHOOK_URL" => nil, "SYRUS_ALERT_EMAIL_TO" => "ops@example.test, oncall@example.test") do
      expect {
        described_class.deliver([ alert ])
      }.to change(ActionMailer::Base.deliveries, :count).by(1)
    end

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to contain_exactly("ops@example.test", "oncall@example.test")
    expect(mail.subject).to eq("[Syrus alarm] Codex usage limit has been reached.")
  end
end
