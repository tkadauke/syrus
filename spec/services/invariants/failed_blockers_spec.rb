require "rails_helper"

RSpec.describe Invariants::FailedBlockers do
  let(:later) { Time.current + 2.hours }
  let(:repository) { Factories.repository }

  def failed_job(**attrs)
    job = Factories.job_with_run(state: "failed", repository: repository,
                                 workflow_attrs: { state: "failed", finished_at: Time.current },
                                 step_attrs: { kind: "prepare", state: "failed" },
                                 run_attrs: { state: "failed", finished_at: Time.current }, **attrs)
    record = RunFailureClassification.find_or_initialize_by(run_id: job.runs.first.id)
    record.update!(classification: "provider_transient", retryable: true, confidence: 0.6, classified_at: Time.current, reason: "The provider failed transiently.")
    job
  end

  it "reports a failed stack parent that queued children wait on" do
    parent = failed_job
    child = Factories.job_record(state: "queued", repository: repository, parent_job_id: parent.id)

    violations = described_class.call(now: later)

    expect(violations.size).to eq(1)
    violation = violations.first
    expect(violation.subject_id).to eq(parent.id)
    expect(violation.details["blocked_jobs"]).to contain_exactly(include("id" => child.id, "relation" => "stack_child", "state" => "queued"))
    expect(violation.details["failure"]).to include("classification" => "provider_transient", "retryable" => true, "step_kind" => "prepare")
    expect(violation.affected_ids["job_ids"]).to contain_exactly(parent.id, child.id)
    expect(violation.message).to include(parent.slug, child.slug)
  end

  it "reports a failed dependency of an approved Job, naming the blocked Epic" do
    epic = Factories.epic(repository: repository, user: repository.user)
    blocker = failed_job(epic_id: epic.id)
    dependent = Factories.job_record(state: "approved", repository: repository, epic_id: epic.id)
    JobDependency.insert_all!([ { job_id: dependent.id, depends_on_job_id: blocker.id, source: "manual", satisfaction_mode: "success",
                                  created_at: Time.current, updated_at: Time.current } ])

    violation = described_class.call(now: later).sole

    expect(violation.details["blocked_jobs"]).to contain_exactly(include("id" => dependent.id, "relation" => "dependency"))
    expect(violation.details["blocked_epic_ids"]).to eq([ epic.id ])
  end

  it "does not report a failed Job nothing waits on" do
    failed_job

    expect(described_class.call(now: later)).to be_empty
  end

  it "does not report a failed Job whose dependents already finished" do
    parent = failed_job
    Factories.job_record(state: "closed", repository: repository, parent_job_id: parent.id)

    expect(described_class.call(now: later)).to be_empty
  end

  it "gives automatic retry the minimum age to act first" do
    parent = failed_job
    Factories.job_record(state: "queued", repository: repository, parent_job_id: parent.id)

    expect(described_class.call(now: Time.current + 10.minutes)).to be_empty
  end
end
