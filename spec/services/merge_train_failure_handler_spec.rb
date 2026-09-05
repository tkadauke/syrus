require "rails_helper"

RSpec.describe MergeTrainFailureHandler, :ci_only do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def member_job(issue_number:, state: "landing")
    Factories.job_record(
      user: user, repository: repository, epic: epic,
      issue_number: issue_number, state: state,
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  def build_train(members)
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master",
                                integration_branch: "syrus/merge-train-epic-#{epic.id}-x")
    members.each_with_index { |job, i| MergeTrainMember.create!(merge_train: train, job: job, position: i) }
    train
  end

  def build_workflow(train, owner_job, failure_reason: nil)
    Workflow.create!(job: owner_job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => train.id },
                      failure_reason: failure_reason)
  end

  describe "#call" do
    it "reverts members with no evidence of landing back to a re-landable state" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      workflow = build_workflow(train, a, failure_reason: "merge_train: some genuine failure")

      described_class.call(workflow: workflow)

      expect(train.reload.state).to eq("failed")
      expect(a.reload.state).to eq("implemented")
      expect(train.members.find_by(job: a).state).to eq("failed")
    end

    # Regression for the JOB-4189 incident: a land step that crashes AFTER
    # GitHub genuinely merged the integration branch (e.g. between
    # record_integration_merge_commit! and reconcile_members! finishing for
    # every member) must not blanket-revert members whose commits are
    # already safely on base -- that would force them through re-approval
    # (or worse, a future re-land) for work that already landed.
    it "does not revert a member whose commits already landed via a real integration merge before the crash" do
      a = member_job(issue_number: 1)
      b = member_job(issue_number: 2)
      train = build_train([ a, b ])
      workflow = build_workflow(train, b, failure_reason: "merge_train: reconcile_members! crashed")
      LandedCommit.create!(landable: epic, sha: "trainsha789", kind: "integration_merge", position: 0)
      LandedCommit.create!(landable: a, sha: "a-landed-1", kind: "implementation", position: 0)
      # `b` never got its build-time commits recorded for this attempt --
      # genuinely not landed, and must still be reverted.

      described_class.call(workflow: workflow)

      expect(a.reload).to be_closed
      expect(a.closure_reason).to eq("pr_merged")
      expect(a.landed_sha).to eq("trainsha789")
      expect(train.members.find_by(job: a).state).to eq("merged")

      expect(b.reload.state).to eq("implemented")
      expect(train.members.find_by(job: b).state).to eq("failed")
      expect(train.reload.state).to eq("failed")
    end

    it "scopes landed-commit evidence to the failing attempt, ignoring stale rows from an earlier attempt" do
      a = member_job(issue_number: 1)
      train = build_train([ a ])
      # A much earlier (unrelated) attempt's LandedCommit for the same Job --
      # must not count as evidence that THIS attempt's train landed it.
      LandedCommit.create!(landable: a, sha: "stale-old-commit", kind: "implementation", position: 0,
                            created_at: 1.day.ago, updated_at: 1.day.ago)
      workflow = build_workflow(train, a, failure_reason: "merge_train: build crashed")
      LandedCommit.create!(landable: epic, sha: "trainsha999", kind: "integration_merge", position: 0)

      described_class.call(workflow: workflow)

      expect(a.reload).not_to be_closed
      expect(a.state).to eq("implemented")
    end

    it "does not touch a member already marked merged" do
      a = member_job(issue_number: 1, state: "closed")
      owner = member_job(issue_number: 2)
      train = build_train([ a ])
      train.members.find_by(job: a).update!(state: "merged")
      workflow = build_workflow(train, owner, failure_reason: "merge_train: unrelated later failure")

      expect { described_class.call(workflow: workflow) }.not_to raise_error

      expect(train.members.find_by(job: a).state).to eq("merged")
    end
  end
end
