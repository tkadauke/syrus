require "rails_helper"

RSpec.describe LandingQueueReentry do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def approved_job
    Factories.job_record(
      user: user,
      repository: repository,
      state: "approved",
      issue_number: 42,
      pr_number: 42,
      branch_name: "syrus/issue-42",
      approved_at: 1.minute.ago,
      approved_via: "operator",
      landing_failure_reason: "landing start blocked: workflow admission budget"
    )
  end

  def blocked_landing_workflow(job, next_check_at:)
    Workflows::AutoMerge.instantiate(job: job).tap do |workflow|
      workflow.update!(
        state: "failed",
        failure_reason: "landing start blocked: workflow admission budget",
        artifacts: {
          "start_blocked_reason" => "landing start blocked: workflow admission budget",
          "start_blocked_at" => 1.minute.ago.iso8601,
          "start_blocked_next_check_at" => next_check_at.iso8601,
          "start_blocked_details" => {
            "action" => "delay_until",
            "reason" => "predicted_budget_pressure_high",
            "delay_until" => next_check_at.iso8601
          }
        }
      )
    end
  end

  it "does not clear a landing admission blocker before its next check time" do
    job = approved_job
    blocked_landing_workflow(job, next_check_at: 8.minutes.from_now)

    expect {
      result = described_class.call(job)
      expect(result.cleared_job_ids).to eq([])
    }.not_to have_enqueued_job(LandingQueueProcessorJob)

    expect(job.reload.landing_failure_reason).to eq("landing start blocked: workflow admission budget")
  end

  it "uses the newest landing admission blocker when older blockers are already due" do
    job = approved_job
    blocked_landing_workflow(job, next_check_at: 1.minute.ago)
    blocked_landing_workflow(job, next_check_at: 8.minutes.from_now)

    expect {
      result = described_class.call(job)
      expect(result.cleared_job_ids).to eq([])
    }.not_to have_enqueued_job(LandingQueueProcessorJob)

    expect(job.reload.landing_failure_reason).to eq("landing start blocked: workflow admission budget")
  end

  it "clears a landing admission blocker once its next check time is due" do
    job = approved_job
    blocked_landing_workflow(job, next_check_at: 1.minute.ago)

    expect {
      result = described_class.call(job)
      expect(result.cleared_job_ids).to eq([ job.id ])
    }.to have_enqueued_job(LandingQueueProcessorJob)

    expect(job.reload.landing_failure_reason).to be_nil
  end

  it "uses the structured failure code, not explanation wording, for reentry candidates" do
    job = approved_job
    job.update!(
      landing_failure_code: LandingFailureCode::LANDING_START_BLOCKED,
      landing_failure_reason: "workflow admission budget delayed this landing attempt"
    )
    blocked_landing_workflow(job, next_check_at: 1.minute.ago)

    expect {
      result = described_class.call(job)
      expect(result.cleared_job_ids).to eq([ job.id ])
    }.to have_enqueued_job(LandingQueueProcessorJob)

    expect(job.reload.landing_failure_code).to be_nil
    expect(job.landing_failure_reason).to be_nil
  end
end
