require "rails_helper"

RSpec.describe MergeTrainAssembler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def child(issue_number:, state: "approved", pr_number: nil, parent_job: nil)
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: issue_number,
      state: state,
      pr_number: pr_number || (1000 + issue_number),
      parent_job: parent_job
    )
  end

  it "is ready when every open child is approved and has a PR" do
    a = child(issue_number: 1)
    b = child(issue_number: 2)

    result = described_class.call(epic)

    expect(result).to be_ready
    expect(result.job_ids).to contain_exactly(a.id, b.id)
  end

  it "orders members topologically (a prerequisite before its dependent)" do
    # Create the dependent first (lower id) so only dependency ordering
    # can put the parent ahead of it.
    parent_placeholder = child(issue_number: 1)
    dependent = child(issue_number: 2, parent_job: parent_placeholder)

    result = described_class.call(epic)

    expect(result).to be_ready
    expect(result.job_ids).to eq([ parent_placeholder.id, dependent.id ])
  end

  it "includes every leaf in an explicit nonlinear fan-in Epic" do
    root = child(issue_number: 1)
    leaf_a = child(issue_number: 2, parent_job: root)
    leaf_b = child(issue_number: 3, parent_job: root)

    result = described_class.call(epic)

    expect(result).to be_ready
    expect(result.job_ids).to eq([ root.id, leaf_a.id, leaf_b.id ])
  end

  it "is not ready when any open child is unapproved" do
    child(issue_number: 1, state: "approved")
    child(issue_number: 2, state: "implemented")

    result = described_class.call(epic)

    expect(result).not_to be_ready
    expect(result.reason).to match(/not yet approved/)
  end

  it "is not ready when a child has no PR" do
    child(issue_number: 1, state: "approved", pr_number: nil)
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 2, state: "approved", pr_number: nil)

    # Override one to truly have no PR.
    epic.jobs.first.update_columns(pr_number: nil)

    result = described_class.call(epic)

    expect(result).not_to be_ready
    expect(result.reason).to match(/without a PR/)
  end

  it "excludes already-merged children from the member set without blocking readiness" do
    a = child(issue_number: 1, state: "approved")
    merged = child(issue_number: 2, state: "closed")
    merged.update_columns(closure_reason: "pr_merged")

    result = described_class.call(epic)

    expect(result).to be_ready
    expect(result.job_ids).to eq([ a.id ])
  end

  it "excludes a historical standalone reconciliation Job from the member set" do
    a = child(issue_number: 1, state: "approved")
    reconciliation = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: nil,
      kind: "direct",
      issue_title: "Reconciliation: #{epic.title}",
      state: "implemented",
      pr_number: nil
    )
    epic.update!(reconciliation_job_id: reconciliation.id)

    result = described_class.call(epic)

    expect(result).to be_ready
    expect(result.job_ids).to eq([ a.id ])
  end

  it "is not ready when there are no open children" do
    result = described_class.call(epic)

    expect(result).not_to be_ready
    expect(result.reason).to match(/no open child/)
  end

  it "is not ready when the epic exceeds merge_train_max_size" do
    AppSetting.current.update!(merge_train_max_size: 1)
    child(issue_number: 1)
    child(issue_number: 2)

    result = described_class.call(epic)

    expect(result).not_to be_ready
    expect(result.reason).to match(/merge_train_max_size/)
  end
end
