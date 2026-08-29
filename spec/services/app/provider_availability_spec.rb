require "rails_helper"

RSpec.describe App::ProviderAvailability do
  let(:now) { Time.zone.parse("2026-07-31 12:00:00 UTC") }
  let(:user) { Factories.user }
  let(:codex_model_decode_failure) do
    "failed to refresh available models: stream disconnected before completion: failed to decode models response: unknown variant `max`, expected none/minimal/low/medium/high/xhigh"
  end

  before do
    Rails.cache.clear
    described_class.clear_cache!
    Current.provider_availability_cache = nil
  end

  def failed_run(provider:, owner: user, outcome: "provider_usage_limit", message: "model gpt-5.5 weekly usage limit exhausted", step_kind: nil, classification: nil)
    job = Factories.job(repository: Factories.repository(user: owner), user: owner, agent_provider: provider)
    step = if outcome == "rate_limited" && step_kind.blank?
      nil
    elsif step_kind
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

  it "forces the latest-provider-run index on MySQL" do
    availability = described_class.new(user: user, provider: "codex", now: now)

    allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Mysql2")

    expect(availability.send(:provider_run_scope_for_latest).to_sql).to include("FORCE INDEX (idx_runs_provider_latest_finished)")
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

  it "shows exhausted Claude usage from structured probe evidence" do
    ProviderAvailabilityEvidence.record_claude_probe!(
      user: user,
      status: "exhausted",
      snapshot: {
        "session_pct" => 100.0,
        "session_reset_minutes" => 60,
        "weekly_pct" => 82.5,
        "weekly_reset_minutes" => 180
      },
      message: "Claude usage limit has been reached.",
      http_status: 200,
      observed_at: now
    )

    status = described_class.for_user(user, "claude", now: now, cached: false)

    expect(status).to include(
      provider: "claude",
      state: "exhausted",
      open: true,
      usage_exhausted: true
    )
    expect(status[:message]).to include("Claude Code usage limit reached")
    expect(status.dig(:usage, :remaining_percent)).to eq(0.0)
    expect(status.dig(:usage, :windows, "five_hour")).to include(
      label: "5h",
      remaining_percent: 0.0,
      used_percent: 100.0
    )
    expect(status.dig(:evidence, :current)).to include(status: "exhausted", source: "usage_probe", provider: "claude")
    expect(Time.zone.parse(status[:retry_after])).to eq(now + 65.minutes)
  end

  it "clears exhausted Claude probe evidence after its reset window expires" do
    ProviderAvailabilityEvidence.record_claude_probe!(
      user: user,
      status: "exhausted",
      snapshot: { "session_pct" => 100.0, "session_reset_minutes" => 60 },
      message: "Claude usage limit has been reached.",
      observed_at: now
    )

    status = described_class.for_user(user, "claude", now: now + 66.minutes, cached: false)

    expect(status).to include(state: "available", open: false, usage_exhausted: false)
    expect(status.dig(:usage, :status)).to eq("exhausted")
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

    status = described_class.for_user(user, "claude", now: now, cached: false)

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

  it "treats newer Codex run success evidence as superseding older matching usage-limit failures" do
    failed_run(provider: "codex", message: "Codex API error: model gpt-5.5 weekly usage limit exhausted")

    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "run_success",
      model: "gpt-5.5",
      observed_at: now
    )

    status = described_class.for_user(user, "codex", now: now, cached: false)

    expect(status).to include(state: "available", open: false, usage_exhausted: false)
    expect(status.dig(:evidence, :latest_positive)).to include(
      status: "available",
      source: "run_success",
      model: "gpt-5.5"
    )
  end

  it "does not extract generic prose words as exhausted Codex models" do
    expect(ProviderUsageLimit.extract_model("invoking agent for direct job failed")).to be_nil
    expect(ProviderUsageLimit.extract_model("provider usage limit exhausted for model for")).to be_nil
  end

  it "does not show exhausted Codex availability for model metadata decode failures" do
    failed_run(
      provider: "codex",
      outcome: "turn_failed",
      classification: "provider_usage_limit",
      message: "failed to refresh available models: failed to decode models response: unknown variant `max`, expected one of none/minimal/low/medium/high/xhigh"
    )

    status = described_class.for_user(user, "codex", now: now, cached: false)

    expect(status).to be_nil
  end

  it "does not show exhausted Codex availability for stale exhausted evidence from model-list decode failures" do
    run = failed_run(
      provider: "codex",
      outcome: "provider_usage_limit",
      message: codex_model_decode_failure
    )
    ProviderAvailabilityEvidence.create!(
      user: user,
      run: run,
      provider: "codex",
      account_id: CodexAccountScope.for_user(user),
      model: "for",
      status: "exhausted",
      source: "codex_invocation_failure",
      observed_at: now - 1.minute,
      details: {
        run_id: run.id,
        agent_outcome: "provider_usage_limit",
        failure_classification: "provider_usage_limit",
        message: codex_model_decode_failure
      }
    )

    status = described_class.for_user(user, "codex", now: now, cached: false)

    expect(status).to be_nil
  end

  it "allows an otherwise admissible queued Codex workflow to create its first Run despite stale false evidence" do
    job = Factories.job_record(
      user: user,
      repository: Factories.repository(user: user),
      state: "open",
      agent_provider: "codex"
    )
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: "codex")
    run = failed_run(
      provider: "codex",
      outcome: "provider_usage_limit",
      message: codex_model_decode_failure
    )
    ProviderAvailabilityEvidence.create!(
      user: user,
      run: run,
      provider: "codex",
      account_id: CodexAccountScope.for_user(user),
      model: "for",
      status: "exhausted",
      source: "codex_invocation_failure",
      observed_at: now - 1.minute,
      details: { message: codex_model_decode_failure }
    )

    created = StepDispatcher.start_workflow(workflow)

    expect(created).to be_present
    expect(created).to be_queued
    expect(created.agent_provider).to eq("codex")
    expect(workflow.reload.artifact("start_blocked_reason")).to be_nil
  end

  it "lets later Codex success suppress bogus model-scoped exhausted evidence" do
    run = failed_run(
      provider: "codex",
      outcome: "provider_usage_limit",
      message: "provider usage limit exhausted for model for"
    )
    ProviderAvailabilityEvidence.record_codex_invocation_failure!(
      run: run,
      model: "for",
      message: "provider usage limit exhausted for model for",
      observed_at: now - 1.minute
    )
    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "chat_turn_success",
      model: "gpt-5.5",
      observed_at: now
    )

    status = described_class.for_user(user, "codex", now: now, cached: false)

    expect(status).to include(state: "available", open: false, usage_exhausted: false)
    expect(status[:message]).not_to include("model for")
  end

  it "does not let a different Codex model success clear model-specific exhaustion" do
    failed_run(provider: "codex", message: "Codex API error: model gpt-5.5 weekly usage limit exhausted")

    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "chat_turn_success",
      model: "gpt-5.4",
      observed_at: now
    )

    status = described_class.for_user(user, "codex", now: now, cached: false)

    expect(status).to include(state: "exhausted", open: true, usage_exhausted: true, model: "gpt-5.5")
    expect(status.dig(:evidence, :latest_positive)).to include(model: "gpt-5.4")
  end

  it "does not show older positive Codex evidence beside a newer warning probe" do
    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "usage_probe",
      model: nil,
      observed_at: now - 2.minutes,
      details: {
        message: "Codex usage has 46% remaining.",
        snapshot: { "remaining_percent" => 46.0 }
      }
    )
    ProviderAvailabilityEvidence.record_codex_probe!(
      user: user,
      status: "warning",
      snapshot: {
        "remaining_percent" => 18.0,
        "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
      },
      message: "Codex usage has 18% remaining.",
      observed_at: now
    )
    user.update!(
      codex_usage_status: "warning",
      codex_usage_observed_at: now,
      codex_usage_snapshot: {
        "remaining_percent" => 18.0,
        "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
      }
    )

    status = described_class.for_user(user, "codex", now: now, cached: false)

    expect(status.dig(:usage, :remaining_percent)).to eq(18.0)
    expect(status.dig(:evidence, :current)).to include(status: "warning")
    expect(status.dig(:evidence, :latest_negative)).to include(status: "warning")
    expect(status.dig(:evidence, :latest_positive)).to be_nil
  end

  it "keeps a provider availability override for low Codex evidence and clears it after measured recovery" do
    user.update!(provider_availability_pause_thresholds: { "codex" => 10 })
    user.override_provider_availability!("codex")
    expect(user.reload.provider_availability_overridden?("codex")).to be(true)

    ProviderAvailabilityEvidence.record_codex_probe!(
      user: user,
      status: "warning",
      snapshot: { "remaining_percent" => 18.0 },
      message: "Codex usage has 18% remaining.",
      observed_at: now
    )

    expect(user.reload.provider_availability_overridden?("codex")).to be(true)

    ProviderAvailabilityEvidence.record_codex_probe!(
      user: user,
      status: "ok",
      snapshot: { "remaining_percent" => 25.0 },
      message: "Codex usage has 25% remaining.",
      observed_at: now + 1.minute
    )

    expect(user.reload.provider_availability_overridden?("codex")).to be(false)
  end

  it "keeps measured low Codex usage even when a later chat turn succeeds" do
    ProviderAvailabilityEvidence.record_codex_probe!(
      user: user,
      status: "warning",
      snapshot: {
        "remaining_percent" => 18.0,
        "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
      },
      message: "Codex usage has 18% remaining.",
      observed_at: now
    )
    user.update!(
      codex_usage_status: "warning",
      codex_usage_observed_at: now,
      codex_usage_snapshot: {
        "remaining_percent" => 18.0,
        "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
      }
    )
    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "chat_turn_success",
      model: "gpt-5.5",
      observed_at: now + 1.minute
    )

    status = described_class.for_user(user, "codex", now: now + 1.minute, cached: false)

    expect(status).to include(state: "available", open: false, usage_exhausted: false)
    expect(status.dig(:usage, :status)).to eq("warning")
    expect(status.dig(:usage, :remaining_percent)).to eq(18.0)
    expect(status.dig(:usage, :evidence)).to include(status: "warning", source: "usage_probe")
    expect(status.dig(:evidence, :current)).to include(status: "available", source: "chat_turn_success")
  end

  it "does not show exhausted availability for inconclusive Codex probe evidence" do
    ProviderAvailabilityEvidence.record_codex_probe!(
      user: user,
      status: "probe_inconclusive",
      snapshot: { "http_status" => 429, "error" => "too many requests" },
      message: "Codex usage probe returned HTTP 429.",
      http_status: 429,
      observed_at: now
    )

    status = described_class.for_user(user, "codex", now: now, cached: false)

    expect(status).to include(state: "available", open: false, usage_exhausted: false)
    expect(status.dig(:usage, :evidence)).to include(status: "probe_inconclusive", source: "usage_probe")
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

  it "lets the database optimizer choose the provider run index" do
    availability = described_class.new(user: user, provider: "codex", now: now)

    sql = availability.send(:provider_run_scope).where(state: "failed").to_sql

    expect(sql).to include("user_id")
    expect(sql).not_to include("FORCE INDEX")
  end

  it "caches provider availability outside the request-local cache" do
    failed_run(provider: "codex")
    shared_cache = {}
    allow(Rails.cache).to receive(:read) { |key| shared_cache[key] }
    allow(Rails.cache).to receive(:write) { |key, value, **_options| shared_cache[key] = value }

    first = described_class.for_user(user, "codex", now: now)
    Current.provider_availability_cache = nil

    expect(described_class).not_to receive(:new)
    second = described_class.for_user(user, "codex", now: now)

    expect(second).to eq(first)
  end

  it "does not keep stale provider availability in a process-local cache after shared cache is cleared" do
    failed_run(provider: "codex")
    shared_cache = {}
    allow(Rails.cache).to receive(:read) { |key| shared_cache[key] }
    allow(Rails.cache).to receive(:write) { |key, value, **_options| shared_cache[key] = value }
    allow(Rails.cache).to receive(:delete) { |key| shared_cache.delete(key) }

    first = described_class.for_user(user, "codex", now: now)
    described_class.clear_cache!(user: user, provider: "codex")
    ProviderAvailabilityEvidence.record_codex_probe!(
      user: user,
      status: "warning",
      snapshot: {
        "remaining_percent" => 18.0,
        "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
      },
      message: "Codex usage has 18% remaining.",
      observed_at: now + 1.minute
    )
    user.update!(
      codex_usage_status: "warning",
      codex_usage_observed_at: now + 1.minute,
      codex_usage_snapshot: {
        "remaining_percent" => 18.0,
        "primary" => { "label" => "weekly", "remaining_percent" => 18.0, "used_percent" => 82.0 }
      }
    )
    Current.provider_availability_cache = nil

    second = described_class.for_user(user, "codex", now: now + 1.minute)

    expect(first.dig(:usage, :remaining_percent)).to be_nil
    expect(second.dig(:usage, :remaining_percent)).to eq(18.0)
  end
end
