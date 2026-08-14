require "rails_helper"

RSpec.describe ManualVisualReviewSubmission do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before { clear_enqueued_jobs }

  def stub_visual_review_plan(enabled:)
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: enabled, rounds: 1, source: ".syrus.yml", note: nil)
    )
  end

  it "dispatches a manual_visual_review workflow for an implemented job" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "implemented")

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(result.workflow.trigger_kind).to eq("manual_visual_review")
    expect(result.workflow.job).to eq(job)
    expect(result.run).to be_present
  end

  it "dispatches for an approved job" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "approved")

    result = described_class.call(job: job)

    expect(result).to be_success
  end

  it "rejects a job that is not implemented or approved" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "running")

    result = described_class.call(job: job)

    expect(result).not_to be_success
    expect(result.error).to include("implemented or approved")
    expect(job.workflows.where(trigger_kind: "manual_visual_review")).to be_empty
  end

  it "rejects a job that already has an active run" do
    stub_visual_review_plan(enabled: true)
    job = Factories.job_record(user: user, repository: repository, state: "implemented")
    job.runs.create!(trigger_kind: "manual_visual_review", agent_provider: job.agent_provider)

    result = described_class.call(job: job)

    expect(result).not_to be_success
    expect(job.workflows.where(trigger_kind: "manual_visual_review")).to be_empty
  end

  it "rejects when visual review is not configured for the repository" do
    stub_visual_review_plan(enabled: false)
    job = Factories.job_record(user: user, repository: repository, state: "implemented")

    result = described_class.call(job: job)

    expect(result).not_to be_success
    expect(result.error).to include("not configured")
    expect(job.workflows.where(trigger_kind: "manual_visual_review")).to be_empty
  end
end
