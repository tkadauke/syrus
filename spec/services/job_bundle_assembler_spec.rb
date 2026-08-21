require "rails_helper"

RSpec.describe JobBundleAssembler do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, auto_merge_enabled: true) }

  def approved(issue_number:, priority: "medium", pr_number: nil, parent_job: nil, kind: "issue")
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: issue_number,
      state: "approved",
      priority: priority,
      pr_number: pr_number || (1000 + issue_number),
      parent_job: parent_job,
      kind: kind
    )
  end

  # external_pr Jobs must be created in :implemented state (validated on
  # create) and with a blank issue_number. Factories.job_record always
  # forces state to "closed" on create then update_columns, so use
  # Job.create! directly for this kind, same as landing_queue_processor_spec.
  def approved_external_pr(external_pr_number:, priority: "medium")
    Job.create!(
      user: user,
      owner_user: user,
      repository: repository,
      kind: "external_pr",
      issue_number: nil,
      external_pr_number: external_pr_number,
      priority: priority,
      state: "implemented"
    ).tap do |job|
      job.approve!(via: "operator")
    end
  end

  it "is not ready when fewer than 2 same-tier candidates exist" do
    approved(issue_number: 1)

    result = described_class.call(repository)

    expect(result).not_to be_ready
    expect(result.reason).to match(/fewer than 2/)
  end

  it "is ready with 2 or more same-tier candidates" do
    a = approved(issue_number: 1)
    b = approved(issue_number: 2)

    result = described_class.call(repository)

    expect(result).to be_ready
    expect(result.priority).to eq("medium")
    expect(result.job_ids).to contain_exactly(a.id, b.id)
  end

  it "does not mix priority tiers into one bundle" do
    approved(issue_number: 1, priority: "urgent")
    approved(issue_number: 2, priority: "medium")
    approved(issue_number: 3, priority: "medium")

    result = described_class.call(repository)

    expect(result).to be_ready
    expect(result.priority).to eq("medium")
    expect(result.members.map(&:priority)).to all(eq("medium"))
  end

  it "prefers the urgent tier when it has enough candidates" do
    urgent_a = approved(issue_number: 1, priority: "urgent")
    urgent_b = approved(issue_number: 2, priority: "urgent")
    approved(issue_number: 3, priority: "medium")
    approved(issue_number: 4, priority: "medium")

    result = described_class.call(repository)

    expect(result.priority).to eq("urgent")
    expect(result.job_ids).to contain_exactly(urgent_a.id, urgent_b.id)
  end

  it "excludes Jobs that belong to an Epic" do
    epic = Factories.epic(user: user, repository: repository)
    Factories.job_record(user: user, repository: repository, epic: epic, issue_number: 1, state: "approved", pr_number: 900)
    approved(issue_number: 2)

    result = described_class.call(repository)

    expect(result).not_to be_ready
  end

  it "excludes external-PR Jobs (they land via Workflows::ExternalPrMerge, not their own PR)" do
    approved_external_pr(external_pr_number: 1)
    approved(issue_number: 2)

    result = described_class.call(repository)

    expect(result).not_to be_ready
  end

  it "excludes Jobs from other repositories" do
    other_repo = Factories.repository(user: user, auto_merge_enabled: true)
    approved(issue_number: 1)
    Factories.job_record(user: user, repository: other_repo, issue_number: 2, state: "approved", pr_number: 2002)

    result = described_class.call(repository)

    expect(result).not_to be_ready
  end

  it "excludes Jobs that are not approved" do
    approved(issue_number: 1)
    Factories.job_record(user: user, repository: repository, issue_number: 2, state: "implemented", pr_number: 1002)

    result = described_class.call(repository)

    expect(result).not_to be_ready
  end

  it "orders members topologically (a prerequisite before its dependent)" do
    parent_placeholder = approved(issue_number: 1)
    dependent = approved(issue_number: 2, parent_job: parent_placeholder)

    result = described_class.call(repository)

    expect(result).to be_ready
    expect(result.job_ids).to eq([ parent_placeholder.id, dependent.id ])
  end

  it "caps bundle size at AppSetting.merge_train_max_size" do
    AppSetting.current.update!(merge_train_max_size: 2)
    a = approved(issue_number: 1)
    b = approved(issue_number: 2)
    approved(issue_number: 3)

    result = described_class.call(repository)

    expect(result).to be_ready
    expect(result.job_ids).to eq([ a.id, b.id ])
  end

  it "shrinks the cap rather than splitting a dependency-linked pair across bundles" do
    AppSetting.current.update!(merge_train_max_size: 3)
    a = approved(issue_number: 1)
    b = approved(issue_number: 2)
    c = approved(issue_number: 3)
    d = approved(issue_number: 4)
    JobDependency.create!(job: d, depends_on_job: c, source: "manual")

    result = described_class.call(repository)

    expect(result).to be_ready
    expect(result.job_ids).to eq([ a.id, b.id ])
  end

  it "is not ready when capping to respect a dependency edge drops below the minimum" do
    AppSetting.current.update!(merge_train_max_size: 2)
    a = approved(issue_number: 1)
    b = approved(issue_number: 2)
    c = approved(issue_number: 3)
    JobDependency.create!(job: c, depends_on_job: b, source: "manual")

    result = described_class.call(repository)

    expect(result).not_to be_ready
  end

  describe ".ready_for_priority?" do
    it "agrees with .call when the tier's candidates fit under the cap" do
      approved(issue_number: 1)
      approved(issue_number: 2)

      expect(described_class.ready_for_priority?(repository, "medium")).to be true
    end

    it "agrees with .call when dependency-edge capping drops the tier below the minimum" do
      AppSetting.current.update!(merge_train_max_size: 2)
      approved(issue_number: 1)
      b = approved(issue_number: 2)
      c = approved(issue_number: 3)
      JobDependency.create!(job: c, depends_on_job: b, source: "manual")

      expect(described_class.ready_for_priority?(repository, "medium")).to be false
    end
  end
end
