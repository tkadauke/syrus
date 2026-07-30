require "rails_helper"

RSpec.describe ProviderCircuitBreaker do
  let(:user) { Factories.user }
  let(:now) { Time.zone.parse("2026-06-02 12:00:00 UTC") }

  def failed_agent_run(provider: "codex", job: nil, outcome: "provider_transient", message: "upstream 503 overloaded")
    job ||= Factories.job(repository: Factories.repository(user: user))
    run = Run.create!(
      job: job,
      step: job.latest_workflow.first_step,
      trigger_kind: "initial",
      state: "failed",
      agent_provider: provider,
      agent_outcome: outcome,
      finished_at: now - 1.minute
    )
    RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed", error_message: message)
    run
  end

  it "opens when recent transient provider failures span unrelated jobs" do
    5.times do |index|
      failed_agent_run(job: Factories.job(repository: Factories.repository(user: user), issue_number: index + 1))
    end

    decision = described_class.call("codex", now: now)

    expect(decision).to be_open
    expect(decision.reason).to eq("repeated upstream error")
    expect(decision.failure_count).to eq(5)
    expect(decision.job_count).to eq(5)
    expect(decision.retry_after).to be_within(1.second).of(now + 9.minutes)
  end

  it "stays closed when failures are isolated to one job" do
    job = Factories.job(repository: Factories.repository(user: user))
    5.times { failed_agent_run(job: job) }

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision.failure_count).to eq(5)
    expect(decision.job_count).to eq(1)
  end

  it "counts repeated rate-limit job logs as retryable provider signals" do
    5.times do |index|
      run = failed_agent_run(
        job: Factories.job(repository: Factories.repository(user: user), issue_number: index + 1),
        outcome: "error",
        message: "agent reported error"
      )
      run.run_diagnostic.destroy!
      JobLog.append!(run: run, chunk: "provider rate-limited this request", kind: "rate_limited")
    end

    decision = described_class.call("codex", now: now)

    expect(decision).to be_open
    expect(decision.reason).to eq("repeated upstream error")
  end

  it "opens immediately for a single provider usage-limit failure" do
    run = failed_agent_run(
      outcome: "provider_usage_limit",
      message: "agent reported provider_usage_limit"
    )
    run.run_diagnostic.update!(
      error_message: "Codex API error: model gpt-5.5 weekly usage limit exhausted; check billing"
    )
    run.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.95,
      retryable: false,
      reason: "usage exhausted",
      classified_at: now
    )

    decision = described_class.call("codex", now: now)

    expect(decision).to be_open
    expect(decision).to be_usage_limit
    expect(decision.reason).to include("usage limit exhausted")
    expect(decision.model).to eq("gpt-5.5")
    expect(decision.retry_after).to be_within(1.second).of(now + 23.hours + 59.minutes)
  end

  it "keeps ordinary 429 rate limits on the existing repeated-failure path" do
    failed_agent_run(outcome: "rate_limited", message: "HTTP 429 too many requests, retry later")

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision.failure_count).to eq(1)
  end

  it "ignores old transient failures outside the rolling window" do
    5.times do |index|
      run = failed_agent_run(job: Factories.job(repository: Factories.repository(user: user), issue_number: index + 1))
      run.update!(finished_at: now - 16.minutes, updated_at: now - 16.minutes)
    end

    expect(described_class.call("codex", now: now)).not_to be_open
  end
end
