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

  it "excludes operator-repaired usage-limit classifications from circuit decisions" do
    run = failed_agent_run(
      outcome: "provider_usage_limit",
      message: "Codex API error: model gpt-5.5 weekly usage limit exhausted"
    )
    classification = run.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.95,
      retryable: false,
      reason: "usage exhausted",
      classified_at: now
    )

    expect(described_class.call("codex", now: now)).to be_open

    classification.mark_circuit_repair!(
      status: "false_positive",
      reason: "Codex model-list decode failure was misclassified as quota.",
      user: Factories.user(admin: true)
    )

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision).not_to be_usage_limit
  end

  it "excludes operator-repaired provider availability evidence from usage-limit decisions" do
    run = failed_agent_run(outcome: "turn_failed", message: "invoking agent for direct job failed")
    evidence = ProviderAvailabilityEvidence.record_codex_invocation_failure!(
      run: run,
      model: "gpt-5.5",
      message: "provider usage limit exhausted for model gpt-5.5",
      observed_at: now - 1.minute
    )

    expect(described_class.call("codex", now: now)).to be_open

    evidence.mark_circuit_repair!(
      status: "false_positive",
      reason: "Failure came from a bad model-list decode response.",
      user: Factories.user(admin: true)
    )

    expect(described_class.call("codex", now: now)).not_to be_open
  end

  it "closes Codex usage-limit circuit when newer matching success evidence exists" do
    run = failed_agent_run(
      outcome: "provider_usage_limit",
      message: "Codex API error: model gpt-5.5 weekly usage limit exhausted"
    )
    run.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.95,
      retryable: false,
      reason: "usage exhausted",
      classified_at: now - 1.minute
    )
    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "run_success",
      model: "gpt-5.5",
      observed_at: now
    )

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision).not_to be_usage_limit
  end

  it "closes transient circuits when newer positive provider evidence exists" do
    5.times do |index|
      failed_agent_run(job: Factories.job(repository: Factories.repository(user: user), issue_number: index + 1))
    end

    expect(described_class.call("codex", now: now)).to be_open

    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "operator_circuit_repair",
      observed_at: now
    )

    expect(described_class.call("codex", now: now)).not_to be_open
  end

  it "suppresses stale Codex usage-limit runs with inconclusive model metadata decode errors" do
    run = failed_agent_run(
      outcome: "turn_failed",
      message: "failed to refresh available models: failed to decode models response: unknown variant `max`, expected one of none/minimal/low/medium/high/xhigh"
    )
    run.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.95,
      retryable: false,
      reason: "stale false-positive usage exhausted",
      classified_at: now - 1.minute
    )

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision).not_to be_usage_limit
  end

  it "lets later Codex success suppress bogus model-scoped usage evidence" do
    ProviderAvailabilityEvidence.record_codex_invocation_failure!(
      run: failed_agent_run(outcome: "provider_usage_limit", message: "invoking agent for direct job failed"),
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

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision).not_to be_usage_limit
  end

  it "keeps Codex usage-limit circuit open when success evidence is for a different model" do
    run = failed_agent_run(
      outcome: "provider_usage_limit",
      message: "Codex API error: model gpt-5.5 weekly usage limit exhausted"
    )
    run.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.95,
      retryable: false,
      reason: "usage exhausted",
      classified_at: now - 1.minute
    )
    ProviderAvailabilityEvidence.record_codex_success!(
      user: user,
      source: "chat_turn_success",
      model: "gpt-5.4",
      observed_at: now
    )

    decision = described_class.call("codex", now: now)

    expect(decision).to be_open
    expect(decision).to be_usage_limit
    expect(decision.model).to eq("gpt-5.5")
  end

  it "uses known usage reset times and closes once that reset has passed" do
    run = failed_agent_run(
      provider: "claude",
      outcome: "provider_usage_limit",
      message: "You're out of extra usage · resets 7am (America/New_York)"
    )
    run.update!(finished_at: Time.zone.parse("2026-08-01 08:30:00 UTC"))
    run.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.95,
      retryable: false,
      reason: "usage exhausted",
      classified_at: run.finished_at
    )

    open_decision = described_class.call("claude", now: Time.zone.parse("2026-08-01 10:00:00 UTC"))
    closed_decision = described_class.call("claude", now: Time.zone.parse("2026-08-01 11:06:00 UTC"))

    expect(open_decision).to be_open
    expect(open_decision.retry_after).to eq(Time.find_zone("America/New_York").parse("2026-08-01 07:05:00"))
    expect(closed_decision).not_to be_open
  end

  it "does not open usage exhaustion from non-agentic grader output or stale classifications" do
    job = Factories.job(repository: Factories.repository(user: user))
    workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", agent_provider: "codex")
    step = Step.create!(workflow: workflow, kind: "grader", position: 0)
    run = Run.create!(
      job: job,
      user: user,
      step: step,
      trigger_kind: "auto_merge",
      state: "failed",
      agent_provider: "codex",
      finished_at: now - 1.minute
    )
    RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed", error_message: "grader react-tests failed (exit 2)")
    JobLog.append!(run: run, chunk: "shows a red usage-limit warning in the job detail header", kind: "grade_log")
    run.create_run_failure_classification!(
      classification: "provider_usage_limit",
      confidence: 0.95,
      retryable: false,
      reason: "usage exhausted",
      classified_at: now
    )

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_usage_limit
  end

  it "keeps ordinary 429 rate limits on the existing repeated-failure path" do
    failed_agent_run(outcome: "rate_limited", message: "HTTP 429 too many requests, retry later")

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision.failure_count).to eq(1)
  end

  it "does not treat worker deaths as provider degradation" do
    5.times do |index|
      failed_agent_run(
        job: Factories.job(repository: Factories.repository(user: user), issue_number: index + 1),
        outcome: "worker_died",
        message: "worker or agent process disappeared during deploy"
      )
    end

    decision = described_class.call("codex", now: now)

    expect(decision).not_to be_open
    expect(decision.failure_count).to eq(0)
  end

  it "does not count stale rate-limit classifications from non-agentic grader failures" do
    5.times do |index|
      job = Factories.job(repository: Factories.repository(user: user), issue_number: index + 1)
      workflow = Workflow.create!(job: job, trigger_kind: "auto_merge", agent_provider: "codex")
      step = Step.create!(workflow: workflow, kind: "grader", position: 0)
      run = Run.create!(
        job: job,
        user: user,
        step: step,
        trigger_kind: "auto_merge",
        state: "failed",
        agent_provider: "codex",
        finished_at: now - 1.minute
      )
      RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed", error_message: "grader rspec failed (exit 1): ActiveRecord::PendingMigrationError")
      JobLog.append!(run: run, chunk: "work_engine action=schedule_retry_after_rate_limit", kind: "system")
      run.create_run_failure_classification!(
        classification: "rate_limited",
        confidence: 0.9,
        retryable: true,
        reason: "stale false-positive rate limit",
        classified_at: now
      )
    end

    expect(described_class.call("codex", now: now)).not_to be_open
  end

  it "ignores old transient failures outside the rolling window" do
    5.times do |index|
      run = failed_agent_run(job: Factories.job(repository: Factories.repository(user: user), issue_number: index + 1))
      run.update!(finished_at: now - 16.minutes, updated_at: now - 16.minutes)
    end

    expect(described_class.call("codex", now: now)).not_to be_open
  end
end
