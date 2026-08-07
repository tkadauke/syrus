require "rails_helper"

RSpec.describe ReconcileJobStatesJob do
  include ActiveJob::TestHelper

  let(:job) do
    j = Factories.job
    j.runs.destroy_all
    j.workflows.destroy_all
    j
  end

  def build_workflow(state:, trigger_kind: "pr_comment", started_at: 5.minutes.ago, finished_at: 1.minute.ago)
    Workflow.create!(
      job: job, trigger_kind: trigger_kind, state: state,
      started_at: started_at,
      finished_at: %w[ succeeded failed cancelled ].include?(state) ? finished_at : nil
    )
  end

  it "always delegates to the unified reconciler without mutating Jobs directly" do
    build_workflow(state: "succeeded")
    job.update!(state: "failed")

    expect {
      described_class.perform_now
    }.to have_enqueued_job(WorkEngine::ReconcileJob).with(
      source: "ReconcileJobStatesJob",
      job_id: nil,
      workflow_id: nil,
      run_id: nil
    )

    expect(job.reload.state).to eq("failed")
  end
end
