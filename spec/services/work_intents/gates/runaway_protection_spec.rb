require "rails_helper"

RSpec.describe WorkIntents::Gates::RunawayProtection do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def intent_for(kind:, scope_type:, scope_id:)
    WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: repository,
      scope_type: scope_type,
      scope_id: scope_id,
      actor: user
    )
  end

  it "passes when no covered job has tripped runaway protection" do
    job = Factories.job_record(user: user, repository: repository)
    intent = intent_for(kind: "initial", scope_type: "job", scope_id: job.id)

    expect(described_class.call(intent)).to be_pass
  end

  it "waits on a job-scoped intent whose job has tripped runaway protection" do
    job = Factories.job_record(user: user, repository: repository, runaway_protection: "too_many_failed_workflows")
    intent = intent_for(kind: "retry", scope_type: "job", scope_id: job.id)

    result = described_class.call(intent)

    expect(result).to be_waiting
    expect(result.reason).to eq("runaway_protection_active")
    expect(result.details["protected_job_ids"]).to eq([ job.id ])
  end

  # The bug this closes: an epic-scoped merge train kept relaunching on its
  # own schedule long after the member job it was landing had already
  # tripped runaway protection from repeated failed workflows -- nothing
  # consulted the flag before admitting the next attempt.
  it "waits on an epic-scoped intent when any open child job has tripped runaway protection" do
    epic = Factories.epic(user: user, repository: repository)
    ok = Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1)
    runaway = Factories.job_record(
      user: user, repository: repository, epic: epic, issue_number: 2,
      runaway_protection: "too_many_failed_workflows"
    )
    intent = intent_for(kind: "merge_train", scope_type: "epic", scope_id: epic.id)

    result = described_class.call(intent)

    expect(result).to be_waiting
    expect(result.details["protected_job_ids"]).to eq([ runaway.id ])
    expect(ok).to be_persisted
  end

  it "passes an epic-scoped intent once runaway protection is cleared" do
    epic = Factories.epic(user: user, repository: repository)
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1)
    intent = intent_for(kind: "merge_train", scope_type: "epic", scope_id: epic.id)

    expect(described_class.call(intent)).to be_pass
  end

  it "passes when the scope_type is unrecognized" do
    job = Factories.job_record(user: user, repository: repository, runaway_protection: "too_many_failed_workflows")
    intent = intent_for(kind: "retry", scope_type: "bogus", scope_id: job.id)

    expect(described_class.call(intent)).to be_pass
  end
end
