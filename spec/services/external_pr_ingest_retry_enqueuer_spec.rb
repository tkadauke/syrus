require "rails_helper"

RSpec.describe ExternalPrIngestRetryEnqueuer do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def same_repo_job(state: "implemented")
    Job.create!(
      user: user, repository: repository,
      kind: "external_pr", state: "implemented",
      external_pr_number: 55, external_pr_fork: false,
      branch_name: "dependabot/bundler/sqlite3-2.9.4"
    ).tap { |j| j.update_columns(state: state) }
  end

  it "rejects non-external_pr Jobs" do
    job = Factories.job(repository: repository)

    result = described_class.call(job: job)

    expect(result).not_to be_success
    expect(result.error).to match(/external PR/i)
  end

  it "rejects when a workflow is already active for the Job" do
    job = same_repo_job
    Workflow.create!(job: job, trigger_kind: "external_pr_ingest", state: "queued")

    result = described_class.call(job: job)

    expect(result).not_to be_success
    expect(result.error).to match(/already running/i)
  end

  it "dispatches a fresh external_pr_ingest workflow and returns the Job to :queued after a failed ingest" do
    job = same_repo_job(state: "failed")

    expect {
      result = described_class.call(job: job)
      expect(result).to be_success
      expect(result.workflow.trigger_kind).to eq("external_pr_ingest")
    }.to change { job.workflows.where(trigger_kind: "external_pr_ingest").count }.by(1)
      .and have_enqueued_job(RunJob)

    expect(job.reload.state).to eq("queued")
  end

  it "dispatches a fresh workflow without a state fixup when the fork Job is already :implemented" do
    job = same_repo_job(state: "implemented")

    result = described_class.call(job: job)

    expect(result).to be_success
    expect(job.reload.state).to eq("implemented")
  end
end
