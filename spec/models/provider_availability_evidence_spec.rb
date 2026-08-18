require "rails_helper"

RSpec.describe ProviderAvailabilityEvidence do
  describe ".record_claude_probe!" do
    let(:user) { Factories.user(claude_oauth_token: "sk-ant-oat01-abc") }

    it "records claude usage-probe evidence with no account scoping" do
      evidence = described_class.record_claude_probe!(
        user: user,
        status: "warning",
        snapshot: { "session_pct" => 90.0 },
        message: "Claude usage is at session 90% used.",
        http_status: 200,
        observed_at: Time.zone.parse("2026-08-18 10:00:00 UTC")
      )

      expect(evidence).to have_attributes(
        user: user,
        provider: "claude",
        account_id: nil,
        model: nil,
        status: "warning",
        source: "usage_probe",
        http_status: 200
      )
      expect(evidence.details).to eq(
        "message" => "Claude usage is at session 90% used.",
        "snapshot" => { "session_pct" => 90.0 }
      )
    end

    it "sanitizes secret-shaped keys out of the persisted details" do
      evidence = described_class.record_claude_probe!(
        user: user,
        status: "available",
        snapshot: { "session_pct" => 1.0, "authorization" => "Bearer sk-ant-oat01-abc" },
        message: "Claude usage snapshot refreshed."
      )

      expect(evidence.details["snapshot"]).not_to have_key("authorization")
    end

    it "rejects a status outside the shared evidence vocabulary" do
      expect {
        described_class.record_claude_probe!(user: user, status: "not_a_real_status", snapshot: {}, message: "x")
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
