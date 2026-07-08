require "rails_helper"

RSpec.describe ResumeWorkflowEnqueuer do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "codex") }
  let(:source_run) { job.initial_run }

  def fail_source_run!
    source_run.start!
    source_run.fail!
    source_run.save!
    source_run.step.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago)
    source_run.step.workflow.update_columns(state: "failed", started_at: 10.minutes.ago, finished_at: 5.minutes.ago)
  end

  it "reopens the failed step instead of creating a new resume workflow" do
    fail_source_run!
    job.update!(state: "failed")
    ClaudeSession.create!(
      resumable: source_run,
      provider: "codex",
      session_id: "codex-thread",
      transcript_jsonl: "{}\n"
    )

    original_workflow = source_run.step.workflow
    failed_step = source_run.step

    result = nil
    expect {
      result = described_class.call(job: job, source_run: source_run)
    }.to have_enqueued_job(RunJob)

    expect(result).to be_success
    expect(result.run.parent_session_id).to eq("codex-thread")
    expect(result.workflow).to eq(original_workflow)
    expect(result.step).to eq(failed_step)
    expect(job.reload.workflows.count).to eq(1)
    expect(job.reload).to be_running
  end

  it "rejects source runs without a captured session" do
    fail_source_run!

    result = described_class.call(job: job, source_run: source_run)

    expect(result).not_to be_success
    expect(result.error).to include("No agent session captured")
  end

  it "rejects active jobs" do
    fail_source_run!
    ClaudeSession.create!(
      resumable: source_run,
      provider: "codex",
      session_id: "codex-thread",
      transcript_jsonl: "{}\n"
    )
    job.runs.create!(trigger_kind: "manual", state: "running", started_at: Time.current)

    result = described_class.call(job: job, source_run: source_run)

    expect(result).not_to be_success
    expect(result.error).to include("already in progress")
  end
end
