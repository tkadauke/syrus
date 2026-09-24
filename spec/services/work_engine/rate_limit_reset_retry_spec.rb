require "rails_helper"

RSpec.describe "WorkEngine rate-limit reset retry planning" do
  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  def reconcile(**attrs)
    WorkEngine::Reconciler.call(source: "rate_limit_reset_retry_spec", **attrs)
  end

  def issue(result, kind)
    result.issues.find { |candidate| candidate.kind == kind.to_s }
  end

  def plan(result, action)
    result.repair_plans.find { |candidate| candidate.action == action.to_s }
  end

  it "plans retryable rate-limit failures for provider-reported reset text instead of fixed backoff" do
    now = Time.zone.parse("2026-09-18 06:14:12 UTC")
    reset_at = Time.zone.parse("2026-09-18 06:45:00 UTC")
    step.update_columns(state: "failed", finished_at: now)
    workflow.update_columns(state: "failed", finished_at: now)
    run.update_columns(
      state: "failed",
      agent_provider: "claude",
      agent_outcome: "rate_limit",
      finished_at: now
    )
    RunDiagnostic.create!(
      run: run,
      error_class: "AgentInvocation::ProviderRateLimit",
      error_message: "You've hit your session limit - resets 6:40am (UTC)"
    )
    replace_failure_classification!(
      run,
      classification: "rate_limited",
      retryable: true,
      confidence: 0.9,
      reason: "The run hit an external rate limit.",
      classified_at: now
    )

    result = reconcile(run_id: run.id, now: now)
    repair_plan = plan(result, :schedule_retry_after_rate_limit)

    expect(issue(result, :retryable_run_failure).retry_after.to_i).to eq(reset_at.to_i)
    expect(repair_plan).to have_attributes(auto_executable: true, target_id: run.id)
    expect(repair_plan.retry_after.to_i).to eq(reset_at.to_i)
    expect(repair_plan.retry_after).to be > now + AutoRetryAttempt::BACKOFFS.first
  end
end
