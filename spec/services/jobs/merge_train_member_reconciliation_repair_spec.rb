require "rails_helper"

RSpec.describe Jobs::MergeTrainMemberReconciliationRepair do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:logger) { instance_double(ActiveSupport::Logger, info: nil, warn: nil) }

  def member_job(issue_number:, state: "landing", pr_number: nil)
    Factories.job_record(
      user: user, repository: repository, epic: epic,
      issue_number: issue_number, state: state,
      pr_number: pr_number || (500 + issue_number),
      branch_name: "syrus/issue-#{issue_number}"
    )
  end

  # Mirrors production ordering: a train is dispatched (created), its build
  # phase records each member's "implementation" LandedCommit, and only then
  # does the land phase mark it succeeded with finished_at. Tests that need
  # a specific train/LandedCommit timing relationship call record_landed_commit!
  # between build_train and land_train! rather than all at once.
  def build_train(members, integration_branch: "syrus/merge-train-epic-#{epic.id}-x")
    train = MergeTrain.create!(
      epic: epic, repository: repository, base_branch: "master",
      integration_branch: integration_branch
    )
    members.each_with_index { |job, i| MergeTrainMember.create!(merge_train: train, job: job, position: i, state: "failed", reason: "not reachable") }
    train
  end

  def land_train!(train, integration_sha: "trainsha789")
    LandedCommit.create!(landable: epic, sha: integration_sha, kind: "integration_merge", position: 0)
    train.update!(state: "succeeded", integration_sha: integration_sha, finished_at: Time.current)
    train
  end

  def record_landed_commit!(job, sha:)
    LandedCommit.create!(landable: job, sha: sha, kind: "implementation", position: 0)
  end

  it "closes a wrongly-failed member as merged when it has its own recorded implementation commit under a successfully landed train" do
    a = member_job(issue_number: 1)
    train = build_train([ a ])
    record_landed_commit!(a, sha: "a-landed-1")
    land_train!(train)

    result = described_class.new(repository: repository, logger: logger).call

    expect(result.checked).to eq(1)
    expect(result.repaired).to eq(1)
    expect(result.skipped).to eq(0)
    expect(result.errors).to eq(0)
    expect(a.reload).to be_closed
    expect(a.closure_reason).to eq("pr_merged")
    expect(a.landed_sha).to eq("trainsha789")
    expect(train.members.find_by(job: a).state).to eq("merged")
  end

  it "leaves a member failed (and does not touch it) when it has no recorded implementation commit for this train" do
    a = member_job(issue_number: 1)
    train = build_train([ a ])
    land_train!(train)

    result = described_class.new(repository: repository, logger: logger).call

    expect(result.checked).to eq(1)
    expect(result.repaired).to eq(0)
    expect(result.skipped).to eq(1)
    expect(a.reload).not_to be_closed
    expect(train.members.find_by(job: a).state).to eq("failed")
  end

  it "does not trust a stale implementation LandedCommit row left by an older, unrelated train attempt" do
    a = member_job(issue_number: 1)

    # An earlier train's build phase recorded `a`'s rebased commits, but
    # that train ultimately failed/was rebuilt for unrelated reasons (e.g.
    # an integration conflict) -- excluded from repair scope by its own
    # `state`, but leaving a stale "implementation" LandedCommit row behind.
    travel_to(2.hours.ago) do
      old_train = build_train([ a ], integration_branch: "syrus/merge-train-epic-#{epic.id}-old")
      record_landed_commit!(a, sha: "a-old-landed")
      old_train.update!(state: "failed", failure_reason: "merge_train failed", finished_at: Time.current)
    end
    # `a` is re-included in a brand new (successful) train; crucially, THIS
    # train's own build phase never records a fresh "implementation" row for
    # it (e.g. a no-op rebase) -- its only LandedCommit predates this train
    # entirely.
    train = build_train([ a ])
    land_train!(train)

    result = described_class.new(repository: repository, logger: logger).call

    expect(result.checked).to eq(1)
    expect(result.repaired).to eq(0)
    expect(result.skipped).to eq(1)
    expect(a.reload).not_to be_closed
    expect(train.members.find_by(job: a).state).to eq("failed")
  end

  it "skips a member whose Job is already closed" do
    a = member_job(issue_number: 1, state: "closed")
    train = build_train([ a ])
    record_landed_commit!(a, sha: "a-landed-1")
    land_train!(train)

    result = described_class.new(repository: repository, logger: logger).call

    expect(result.skipped).to eq(1)
    expect(result.repaired).to eq(0)
  end

  it "does not touch trains that never landed" do
    a = member_job(issue_number: 1)
    train = MergeTrain.create!(
      epic: epic, repository: repository, base_branch: "master",
      integration_branch: "syrus/merge-train-epic-#{epic.id}-x", state: "failed", finished_at: Time.current
    )
    MergeTrainMember.create!(merge_train: train, job: a, position: 0, state: "failed", reason: "not reachable")
    record_landed_commit!(a, sha: "a-landed-1")

    result = described_class.new(repository: repository, logger: logger).call

    expect(result.checked).to eq(0)
    expect(a.reload).not_to be_closed
  end

  it "does not touch members that already merged" do
    a = member_job(issue_number: 1)
    b = member_job(issue_number: 2)
    train = build_train([ a, b ])
    record_landed_commit!(a, sha: "a-landed-1")
    record_landed_commit!(b, sha: "b-landed-1")
    land_train!(train)
    train.members.find_by(job: b).update!(state: "merged")
    b.close_with_reason!("pr_merged")

    result = described_class.new(repository: repository, logger: logger).call

    expect(result.checked).to eq(1)
    expect(result.repaired).to eq(1)
    expect(a.reload).to be_closed
  end

  it "supports dry_run without mutating any records" do
    a = member_job(issue_number: 1)
    train = build_train([ a ])
    record_landed_commit!(a, sha: "a-landed-1")
    land_train!(train)

    result = described_class.new(repository: repository, logger: logger).call(dry_run: true)

    expect(result.repaired).to eq(1)
    expect(a.reload).not_to be_closed
    expect(train.members.find_by(job: a).state).to eq("failed")
  end

  it "scopes to a specific train id when given" do
    a = member_job(issue_number: 1)
    b = member_job(issue_number: 2)
    train_a = build_train([ a ], integration_branch: "syrus/merge-train-epic-#{epic.id}-a")
    record_landed_commit!(a, sha: "a-landed-1")
    land_train!(train_a, integration_sha: "trainsha-a")
    train_b = build_train([ b ], integration_branch: "syrus/merge-train-epic-#{epic.id}-b")
    record_landed_commit!(b, sha: "b-landed-1")
    land_train!(train_b, integration_sha: "trainsha-b")

    result = described_class.new(repository: repository, logger: logger).call(train_ids: [ train_a.id ])

    expect(result.checked).to eq(1)
    expect(a.reload).to be_closed
    expect(b.reload).not_to be_closed
  end
end
