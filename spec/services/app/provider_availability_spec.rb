require "rails_helper"

RSpec.describe App::ProviderAvailability do
  let(:now) { Time.zone.parse("2026-07-31 12:00:00 UTC") }
  let(:user) { Factories.user }

  before do
    Rails.cache.clear
    described_class.clear_cache!
    Current.provider_availability_cache = nil
  end

  def failed_run(provider:, owner: user, outcome: "provider_usage_limit", message: "model gpt-5.5 weekly usage limit exhausted", step_kind: nil, classification: nil)
    job = Factories.job(repository: Factories.repository(user: owner), user: owner, agent_provider: provider)
    step = if step_kind
      workflow = Workflow.create!(job: job, user: owner, trigger_kind: "auto_merge", agent_provider: provider)
      Step.create!(workflow: workflow, kind: step_kind, position: 0)
    else
      job.latest_workflow.first_step
    end
    run = Run.create!(
      job: job,
      user: owner,
      step: step,
      trigger_kind: "initial",
      state: "failed",
      agent_provider: provider,
      agent_outcome: outcome,
      finished_at: now - 1.minute
    )
    RunDiagnostic.create!(run: run, error_class: "ProviderError", error_message: message)
    classification ||= outcome if outcome == "provider_usage_limit"
    if classification
      run.create_run_failure_classification!(
        classification: classification,
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

  it "uses known provider reset times and clears exhausted state after the reset" do
    failed_run(
      provider: "claude",
      outcome: "provider_usage_limit",
      message: "You're out of extra usage · resets 7am (America/New_York)"
    ).update!(finished_at: Time.zone.parse("2026-08-01 08:30:00 UTC"))

    before_reset = described_class.for_user(user, "claude", now: Time.zone.parse("2026-08-01 10:00:00 UTC"), cached: false)
    after_reset = described_class.for_user(user, "claude", now: Time.zone.parse("2026-08-01 11:06:00 UTC"), cached: false)

    expect(before_reset).to include(state: "exhausted")
    expect(Time.zone.parse(before_reset[:retry_after])).to eq(Time.zone.parse("2026-08-01T11:05:00Z"))
    expect(after_reset).to be_nil
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

  it "treats the user's latest provider rate-limit failure as provider-wide until a later success clears it" do
    rate_limited = failed_run(
      provider: "claude",
      outcome: "rate_limited",
      message: "Claude is rate-limited, retry later",
      classification: "rate_limited"
    )

    status = described_class.for_user(user, "claude", now: now)

    expect(status).to include(
      provider: "claude",
      state: "rate_limited",
      open: true,
      usage_exhausted: false
    )
    expect(status[:message]).to include("until a later Claude Code run completes without a rate-limit failure")

    later_job = Factories.job(repository: Factories.repository(user: user), user: user, agent_provider: "claude")
    Run.create!(
      job: later_job,
      user: user,
      step: later_job.latest_workflow.first_step,
      trigger_kind: "initial",
      state: "succeeded",
      agent_provider: "claude",
      finished_at: rate_limited.finished_at + 1.minute
    )

    expect(described_class.for_user(user, "claude", now: now, cached: false)).to be_nil
  end

  it "does not trust stale rate-limit classifications without direct provider evidence" do
    failed_run(
      provider: "codex",
      outcome: nil,
      classification: "rate_limited",
      message: "grader rspec failed (exit 1): ActiveRecord::PendingMigrationError",
      step_kind: "grader"
    ).tap do |run|
      JobLog.append!(run: run, chunk: "work_engine action=schedule_retry_after_rate_limit", kind: "system")
    end

    expect(described_class.for_user(user, "codex", now: now)).to be_nil
  end

  it "shows rate-limited availability for direct provider 429 diagnostics" do
    failed_run(
      provider: "codex",
      outcome: "turn_failed",
      classification: "rate_limited",
      message: "[codex error] HTTP 429 too many requests",
      step_kind: "implement"
    )

    expect(described_class.for_user(user, "codex", now: now)).to include(
      provider: "codex",
      state: "rate_limited",
      usage_exhausted: false
    )
  end

  it "shows rate-limited availability for classifications backed by explicit rate-limited log kinds" do
    failed_run(
      provider: "codex",
      outcome: "turn_failed",
      classification: "rate_limited",
      message: "provider invocation failed",
      step_kind: "implement"
    ).run_failure_classification.update!(
      classifier_inputs: { "job_log_kinds" => [ "rate_limited" ] }
    )

    expect(described_class.for_user(user, "codex", now: now)).to include(
      provider: "codex",
      state: "rate_limited",
      usage_exhausted: false
    )
  end

  it "includes Codex 5-hour and weekly usage percentages when a usage snapshot exists" do
    user.update!(
      codex_usage_status: "ok",
      codex_usage_observed_at: now,
      codex_usage_snapshot: {
        "remaining_percent" => 16.2,
        "primary" => { "label" => "5h", "remaining_percent" => 58.4, "used_percent" => 41.6, "reset_at" => "2026-07-31T15:00:00Z" },
        "secondary" => { "label" => "weekly", "remaining_percent" => 16.2, "used_percent" => 83.8, "reset_at" => "2026-08-07T12:00:00Z" }
      }
    )

    status = described_class.for_user(user, "codex", now: now)

    expect(status).to include(provider: "codex", state: "available", open: false, usage_exhausted: false)
    expect(status.dig(:usage, :remaining_percent)).to eq(16.2)
    expect(status.dig(:usage, :windows, "five_hour")).to include(
      label: "5h",
      remaining_percent: 58.4
    )
    expect(status.dig(:usage, :windows, "weekly")).to include(
      label: "weekly",
      remaining_percent: 16.2
    )
  end

  it "ignores usage-limit words and stale usage classifications from non-agentic grader runs" do
    failed_run(
      provider: "codex",
      outcome: nil,
      classification: "provider_usage_limit",
      message: "grader react-tests failed (exit 2)",
      step_kind: "grader"
    ).tap do |run|
      JobLog.append!(run: run, chunk: "shows a red usage-limit warning in the job detail header", kind: "grade_log")
    end

    expect(described_class.for_user(user, "codex", now: now)).to be_nil
  end

  it "does not scan job logs while checking provider availability" do
    failed_run(
      provider: "codex",
      outcome: nil,
      classification: nil,
      message: "generic failure"
    ).tap do |run|
      JobLog.append!(run: run, chunk: "model gpt-5.5 weekly usage limit exhausted", kind: "system")
    end

    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql].to_s if payload[:sql].to_s.include?("job_logs")
    end

    status = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.for_user(user, "codex", now: now, cached: false)
    end

    expect(status).to be_nil
    expect(queries).to be_empty
  end

  it "caches provider availability outside the request-local cache" do
    failed_run(provider: "codex")
    allow(Rails.cache).to receive(:fetch).and_call_original

    first = described_class.for_user(user, "codex", now: now)
    Current.provider_availability_cache = nil

    expect(described_class).not_to receive(:new)
    second = described_class.for_user(user, "codex", now: now)

    expect(second).to eq(first)
    expect(Rails.cache).not_to have_received(:fetch)
  end
end
