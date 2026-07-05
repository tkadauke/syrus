require "rails_helper"

RSpec.describe Maintenance::ReleaseStuckEpicBlockedJobs do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "releases blocked_by_epic jobs whose epic and job deps are both satisfied" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    prerequisite = Factories.job_record(
      user: user, repository: repository, epic: epic, issue_number: 42,
      state: "implemented", branch_name: "syrus/issue-42", pr_number: 7
    )
    job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, state: "blocked_by_epic")
    Workflows::Initial.instantiate(job: job)
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
    prerequisite.update_columns(state: "approved")

    result = described_class.call

    expect(result.released_count).to eq(1)
    expect(result.skipped_count).to eq(0)
    expect(job.reload).to be_queued
  end

  it "skips blocked_by_epic jobs whose epic does not release for execution" do
    epic = Factories.epic(user: user, repository: repository, state: "ready")
    job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, state: "blocked_by_epic")

    result = described_class.call

    expect(result.released_count).to eq(0)
    expect(result.skipped_count).to eq(1)
    expect(job.reload).to be_blocked_by_epic
  end

  it "skips blocked_by_epic jobs whose job-level deps are not yet satisfied" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 42, state: "queued")
    job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, state: "blocked_by_epic")
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

    result = described_class.call

    expect(result.released_count).to eq(0)
    expect(result.skipped_count).to eq(1)
    expect(job.reload).to be_blocked_by_epic
  end

  it "is idempotent: re-running after all jobs are released returns zero released" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress")
    job = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 43, state: "blocked_by_epic")
    Workflows::Initial.instantiate(job: job)

    first = described_class.call
    second = described_class.call

    expect(first.released_count).to eq(1)
    expect(second.released_count).to eq(0)
    expect(second.skipped_count).to eq(0)
  end
end
