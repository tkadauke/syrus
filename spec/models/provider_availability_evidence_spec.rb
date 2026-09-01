require "rails_helper"

RSpec.describe ProviderAvailabilityEvidence do
  describe ".record_invocation_auth_error!" do
    let(:user) { Factories.user }
    let(:job) { Factories.job(user: user, repository: Factories.repository(user: user), agent_provider: "codex") }
    let(:run) { job.initial_run }

    it "records provider auth-expired evidence without leaking token-shaped details" do
      run.update!(agent_provider: "codex", agent_outcome: "turn_failed")
      run.create_run_failure_classification!(
        classification: "provider_auth_expired",
        confidence: 0.95,
        retryable: false,
        reason: "expired auth",
        classified_at: Time.current
      )

      evidence = described_class.record_invocation_auth_error!(
        run: run,
        message: "HTTP 401 token_expired: sign in again",
        http_status: 401,
        observed_at: Time.zone.parse("2026-08-31 10:00:00 UTC")
      )

      expect(evidence).to have_attributes(
        user: user,
        run: run,
        provider: "codex",
        account_id: CodexAccountScope.for_user(user),
        model: nil,
        status: "auth_error",
        source: "codex_invocation_auth_error",
        http_status: 401
      )
      expect(evidence.details).to include(
        "run_id" => run.id,
        "agent_outcome" => "turn_failed",
        "failure_classification" => "provider_auth_expired",
        "message" => "HTTP 401 token_expired: sign in again"
      )
    end
  end

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
