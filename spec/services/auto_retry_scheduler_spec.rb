require "rails_helper"

RSpec.describe AutoRetryScheduler do
  include ActiveJob::TestHelper

  let(:job) { Factories.job(agent_provider: "claude") }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.first_step }
  let(:run) { step.runs.first }

  around do |example|
    clear_enqueued_jobs
    clear_performed_jobs
    example.run
    clear_enqueued_jobs
    clear_performed_jobs
  end

  def fail_workflow!(agent_outcome: "worker_died", cleaned_up: false)
    run.update!(state: "failed", agent_outcome: agent_outcome, agent_provider: "claude", finished_at: Time.current)
    step.update!(state: "failed", finished_at: Time.current)
    workflow.update!(state: "failed", finished_at: Time.current, cleaned_up_at: (Time.current if cleaned_up))
    job.update!(state: "failed")
  end

  it "schedules a delayed failed-step retry for retryable failures with workspace available" do
    freeze_time do
      fail_workflow!

      expect {
        described_class.schedule_for_workflow(workflow: workflow)
      }.to change { AutoRetryAttempt.count }.by(1)
        .and have_enqueued_job(AutoRetryJob)

      attempt = AutoRetryAttempt.last
      expect(attempt).to have_attributes(
        job_id: job.id,
        workflow_id: workflow.id,
        run_id: run.id,
        agent_provider: "claude",
        failure_classification: "worker_died",
        retry_kind: "failed_step",
        attempt_number: 1,
        scheduled_at: 5.minutes.from_now
      )
    end
  end

  it "does not schedule non-retryable failures" do
    fail_workflow!(agent_outcome: "error_max_turns")

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.not_to change { AutoRetryAttempt.count }
  end

  it "caps attempts per job provider and failure classification" do
    fail_workflow!
    3.times do |i|
      AutoRetryAttempt.create!(
        job: job,
        workflow: workflow,
        run: run,
        agent_provider: "claude",
        failure_classification: "worker_died",
        retry_kind: "failed_step",
        attempt_number: i + 1,
        scheduled_at: Time.current
      )
    end

    expect {
      described_class.schedule_for_workflow(workflow: workflow)
    }.not_to change { AutoRetryAttempt.count }
  end

  it "falls back to a retry workflow when the failed workspace is gone" do
    fail_workflow!(cleaned_up: true)

    described_class.schedule_for_workflow(workflow: workflow)

    attempt = AutoRetryAttempt.last
    expect(attempt.retry_kind).to eq("retry_workflow")
  end
end
