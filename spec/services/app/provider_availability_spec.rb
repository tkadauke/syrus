require "rails_helper"

RSpec.describe App::ProviderAvailability do
  let(:now) { Time.zone.parse("2026-07-31 12:00:00 UTC") }
  let(:user) { Factories.user }

  def failed_run(provider:, owner: user, outcome: "provider_usage_limit", message: "model gpt-5.5 weekly usage limit exhausted")
    job = Factories.job(repository: Factories.repository(user: owner), user: owner, agent_provider: provider)
    run = Run.create!(
      job: job,
      user: owner,
      step: job.latest_workflow.first_step,
      trigger_kind: "initial",
      state: "failed",
      agent_provider: provider,
      agent_outcome: outcome,
      finished_at: now - 1.minute
    )
    RunDiagnostic.create!(run: run, error_class: "ProviderError", error_message: message)
    if outcome == "provider_usage_limit"
      run.create_run_failure_classification!(
        classification: outcome,
        confidence: 0.95,
        retryable: false,
        reason: "usage exhausted",
        classified_at: now
      )
    end
    run
  end

  it "marks only the exhausted provider for the current user" do
    failed_run(provider: "codex")

    codex = described_class.for_user(user, "codex", now: now)
    claude = described_class.for_user(user, "claude", now: now)

    expect(codex).to include(provider: "codex", state: "exhausted", usage_exhausted: true, model: "gpt-5.5")
    expect(codex[:message]).to include("Codex usage limit reached")
    expect(claude).to be_nil
  end

  it "does not leak another user's exhausted provider state" do
    failed_run(provider: "codex", owner: Factories.user)

    expect(described_class.for_user(user, "codex", now: now)).to be_nil
  end

  it "clears the exhausted marker after the usage-limit window expires" do
    run = failed_run(provider: "codex")
    run.update!(finished_at: now - ProviderCircuitBreaker::USAGE_LIMIT_WINDOW - 1.minute)

    expect(described_class.for_user(user, "codex", now: now)).to be_nil
  end

  it "keeps transient circuit state separate from red usage exhaustion" do
    5.times do |index|
      run = failed_run(
        provider: "codex",
        outcome: "provider_transient",
        message: "upstream 503 overloaded",
        owner: user
      )
      run.job.update!(issue_number: index + 100)
    end

    status = described_class.for_user(user, "codex", now: now)

    expect(status).to include(provider: "codex", state: "open", usage_exhausted: false)
    expect(status[:message]).to include("temporarily unavailable")
  end
end
