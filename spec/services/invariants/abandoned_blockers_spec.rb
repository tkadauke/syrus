require "rails_helper"

RSpec.describe Invariants::AbandonedBlockers do
  let(:later) { Time.current + 2.hours }
  let(:repository) { Factories.repository }

  def depend!(dependent, on_job: nil, on_epic: nil, mode: "success")
    JobDependency.insert_all!([ { job_id: dependent.id, depends_on_job_id: on_job&.id, depends_on_epic_id: on_epic&.id,
                                  source: "manual", satisfaction_mode: mode, created_at: Time.current, updated_at: Time.current } ])
  end

  it "reports a dependency whose PR was closed unmerged while its dependent waits" do
    blocker = Factories.job_record(state: "closed", closure_reason: "pr_closed", repository: repository)
    dependent = Factories.job_record(state: "queued", repository: repository)
    depend!(dependent, on_job: blocker)

    violation = described_class.call(now: later).sole

    expect(violation.subject_type).to eq("Job")
    expect(violation.subject_id).to eq(blocker.id)
    expect(violation.details).to include("blocker_kind" => "job", "closure_reason" => "pr_closed")
    expect(violation.details["blocked_jobs"]).to contain_exactly(include("id" => dependent.id))
    expect(violation.message).to include(blocker.slug, dependent.slug)
  end

  it "does not report a dependency that closed successfully" do
    blocker = Factories.job_record(state: "closed", closure_reason: "pr_merged", repository: repository)
    depend!(Factories.job_record(state: "queued", repository: repository), on_job: blocker)

    expect(described_class.call(now: later)).to be_empty
  end

  it "does not report a closed dependency whose satisfaction mode accepts any close" do
    blocker = Factories.job_record(state: "closed", closure_reason: "pr_closed", repository: repository)
    depend!(Factories.job_record(state: "queued", repository: repository), on_job: blocker, mode: "closed")

    expect(described_class.call(now: later)).to be_empty
  end

  it "reports an Epic dependency whose Jobs all closed while the Epic never finished" do
    epic = Factories.epic(repository: repository, user: repository.user)
    Factories.job_record(state: "closed", closure_reason: "pr_closed", repository: repository, epic_id: epic.id)
    dependent = Factories.job_record(state: "blocked_by_epic", repository: repository)
    depend!(dependent, on_epic: epic)

    violation = described_class.call(now: later).sole

    expect(violation.subject_type).to eq("Epic")
    expect(violation.details).to include("blocker_kind" => "epic")
    expect(violation.details["blocked_jobs"]).to contain_exactly(include("id" => dependent.id))
  end

  it "does not report an Epic dependency that still has open work" do
    epic = Factories.epic(repository: repository, user: repository.user)
    Factories.job_record(state: "closed", closure_reason: "pr_closed", repository: repository, epic_id: epic.id)
    Factories.job_record(state: "queued", repository: repository, epic_id: epic.id)
    depend!(Factories.job_record(state: "blocked_by_epic", repository: repository), on_epic: epic)

    expect(described_class.call(now: later)).to be_empty
  end

  it "gives a fresh closure the minimum age" do
    blocker = Factories.job_record(state: "closed", closure_reason: "pr_closed", repository: repository)
    depend!(Factories.job_record(state: "queued", repository: repository), on_job: blocker)

    expect(described_class.call(now: Time.current)).to be_empty
  end
end
