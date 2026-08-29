require "rails_helper"

RSpec.describe DefaultProviderChangeWakeup do
  include ActiveJob::TestHelper

  let(:user) { Factories.user(agent_provider: "codex", codex_api_key: "ck-test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repository, agent_provider: "claude", job_provider_setting: "default") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  it "skips stale usage-limit auto retries and asks the reconciler to retry default-provider jobs" do
    run.update!(
      state: "failed",
      agent_provider: "claude",
      agent_outcome: ProviderUsageLimit::OUTCOME,
      finished_at: Time.current
    )
    classification = run.run_failure_classification || run.build_run_failure_classification
    classification.update!(
      classification: ProviderUsageLimit::CLASSIFICATION,
      retryable: false,
      confidence: 0.95,
      reason: "provider usage exhausted",
      classified_at: Time.current
    )
    attempt = AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: ProviderUsageLimit::CLASSIFICATION,
      retry_kind: "failed_step",
      attempt_number: 1,
      scheduled_at: 1.hour.from_now
    )
    allow(WorkEngine::Reconciler).to receive(:request)

    result = described_class.call(user: user, previous_provider: "claude", current_provider: "codex")

    expect(result.job_ids).to include(job.id)
    expect(result.skipped_auto_retry_attempt_ids).to eq([ attempt.id ])
    expect(attempt.reload.skipped_reason).to eq("default provider changed from claude to codex; reconciler will retry with codex")
    expect(WorkEngine::Reconciler).to have_received(:request).with(source: "DefaultProviderChangeWakeup", job: job)
  end

  it "leaves explicit-provider jobs pinned to their selected provider" do
    job.update!(job_provider_setting: "claude")
    allow(WorkEngine::Reconciler).to receive(:request)

    result = described_class.call(user: user, previous_provider: "claude", current_provider: "codex")

    expect(result.job_ids).to be_empty
    expect(WorkEngine::Reconciler).not_to have_received(:request)
  end

  it "cancels active provider-blocked WorkUnits whose workflow provider is stale" do
    workflow.update!(agent_provider: "claude", state: "running", started_at: 5.minutes.ago)
    step.update!(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
    run.update!(state: "succeeded", agent_provider: "claude", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
    unit = attach_work_unit(
      workflow,
      state: "blocked",
      blocked_reason: WorkUnits::Gates::ProviderAvailability::REASON,
      blocked_until: 1.day.from_now
    )

    result = described_class.call(user: user, previous_provider: "claude", current_provider: "codex")

    expect(result.released_work_unit_ids).to eq([ unit.id ])
    expect(workflow.reload).to be_cancelled
    expect(unit.reload).to have_attributes(state: "cancelled", preemption_reason: WorkUnits::StaleProviderRelauncher::PREEMPTION_REASON)
  end
end
