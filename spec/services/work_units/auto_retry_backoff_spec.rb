require "rails_helper"

RSpec.describe WorkUnits::AutoRetryBackoff do
  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:run) { workflow.first_step.runs.first }
  let(:intent) do
    WorkIntent.create!(
      kind: workflow.trigger_kind,
      state: "requested",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      actor: job.user,
      source_type: "spec"
    )
  end
  let(:unit) do
    (workflow.work_unit || WorkUnit.create!(
      work_intent: intent,
      kind: workflow.trigger_kind,
      state: "queued",
      repository: job.repository,
      scope_type: "job",
      scope_id: job.id,
      workflow: workflow
    )).tap do |work_unit|
      work_unit.update!(state: "failed", blocked_reason: nil, blocked_until: nil, blocked_details: {})
      work_unit.work_unit_members.find_or_create_by!(job: job) { |member| member.role = "primary" }
      work_unit.work_unit_locks.active.find_each(&:release!)
    end
  end

  def attempt!(retry_kind:, scheduled_at: 5.minutes.from_now)
    AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: run,
      agent_provider: "claude",
      failure_classification: "timeout",
      retry_kind: retry_kind,
      attempt_number: 1,
      scheduled_at: scheduled_at
    )
  end

  it "blocks the same work unit while a same-attempt retry is sleeping" do
    workflow.update!(work_unit: unit)
    attempt = attempt!(retry_kind: "failed_step")

    described_class.record!(attempt)

    expect(unit.reload).to have_attributes(
      state: "blocked",
      blocked_reason: "auto_retry_backoff"
    )
    expect(unit.blocked_until.to_i).to eq(attempt.scheduled_at.to_i)
    expect(unit.blocked_details).to include(
      "auto_retry_attempt_id" => attempt.id,
      "retry_kind" => "failed_step",
      "failure_classification" => "timeout"
    )
    expect(unit.work_unit_locks.active.pluck(:lock_key)).to include("job:#{job.id}")
  end

  it "does not block the old unit for retry workflows that create a new attempt" do
    workflow.update!(work_unit: unit)
    attempt = attempt!(retry_kind: "retry_workflow")

    described_class.record!(attempt)

    expect(unit.reload).to have_attributes(state: "failed", blocked_reason: nil)
    expect(unit.work_unit_locks.active).to be_empty
  end

  it "terminalizes the unit again when the sleeping same-attempt retry is skipped" do
    workflow.update!(work_unit: unit)
    attempt = attempt!(retry_kind: "resume_failed_step")
    described_class.record!(attempt)

    described_class.clear!(attempt)

    expect(unit.reload).to have_attributes(state: "failed", blocked_reason: nil)
    expect(unit.work_unit_locks.active).to be_empty
  end
end
