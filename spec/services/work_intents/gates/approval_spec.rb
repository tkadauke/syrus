require "rails_helper"

RSpec.describe WorkIntents::Gates::Approval do
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

  it "passes when the definition doesn't require approval" do
    job = Factories.job_record(user: user, repository: repository)
    intent = intent_for(kind: "initial", scope_type: "job", scope_id: job.id)

    expect(described_class.call(intent)).to be_pass
  end

  it "waits on a job-scoped intent until the job is approved or landing" do
    job = Factories.job_record(user: user, repository: repository)
    intent = intent_for(kind: "auto_merge", scope_type: "job", scope_id: job.id)

    result = described_class.call(intent)

    expect(result).to be_waiting
    expect(result.details["waiting_job_ids"]).to eq([ job.id ])
  end

  it "passes a job-scoped intent once the job is approved" do
    job = Factories.job_record(user: user, repository: repository, state: "approved")
    intent = intent_for(kind: "auto_merge", scope_type: "job", scope_id: job.id)

    expect(described_class.call(intent)).to be_pass
  end

  it "waits on an epic-scoped intent until every open child job is approved or landing" do
    epic = Factories.epic(user: user, repository: repository)
    Factories.job_record(user: user, repository: repository, epic: epic, state: "approved", issue_number: 1)
    waiting = Factories.job_record(user: user, repository: repository, epic: epic, state: "implemented", issue_number: 2)
    intent = intent_for(kind: "merge_train", scope_type: "epic", scope_id: epic.id)

    result = described_class.call(intent)

    expect(result).to be_waiting
    expect(result.details["waiting_job_ids"]).to eq([ waiting.id ])
  end

  it "passes a repository-scoped intent (bundle membership isn't tracked on the intent yet)" do
    intent = intent_for(kind: "job_bundle", scope_type: "repository", scope_id: repository.id)

    expect(described_class.call(intent)).to be_pass
  end

  it "passes when the scope_type is unrecognized" do
    job = Factories.job_record(user: user, repository: repository)
    intent = intent_for(kind: "auto_merge", scope_type: "bogus", scope_id: job.id)

    expect(described_class.call(intent)).to be_pass
  end
end
