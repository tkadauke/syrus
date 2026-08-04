require "rails_helper"

RSpec.describe RunResourceSummaryPruneJob do
  it "keeps detailed summaries for thirty days" do
    freeze_time do
      old = create_summary!(created_at: (RunResourceSummary::RETAIN_AFTER + 1.second).ago)
      boundary = create_summary!(created_at: RunResourceSummary::RETAIN_AFTER.ago)
      fresh = create_summary!(created_at: 1.hour.ago)

      described_class.perform_now

      expect(RunResourceSummary.exists?(old.id)).to be(false)
      expect(RunResourceSummary.exists?(boundary.id)).to be(true)
      expect(RunResourceSummary.exists?(fresh.id)).to be(true)
    end
  end

  def create_summary!(created_at:)
    job = Factories.job_record(state: "running")
    workflow = Workflow.create!(job: job, user: job.user, trigger_kind: "initial", state: "running")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "running")
    run = step.runs.create!(job: job, user: job.user, trigger_kind: "initial", state: "succeeded", started_at: 1.minute.ago, finished_at: Time.current)
    summary = RunResourceSummary.create!(
      run: run,
      job: job,
      workflow: workflow,
      step: step,
      repository: job.repository,
      user: job.user,
      agent_provider: "codex",
      trigger_kind: "initial",
      step_kind: "implement",
      started_at: run.started_at,
      finished_at: run.finished_at,
      duration_seconds: 60.0,
      sample_confidence: "unknown",
      resource_pressure_level: "unknown",
      resource_pressure_reasons: [],
      summary_version: RunResourceSummary::SUMMARY_VERSION
    )
    summary.update_columns(created_at: created_at, updated_at: created_at)
    summary
  end
end
