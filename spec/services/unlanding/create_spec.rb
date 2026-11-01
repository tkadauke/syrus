require "rails_helper"

RSpec.describe Unlanding::Create do
  let(:original) do
    Factories.job_record(state: "closed", closure_reason: "pr_merged", landed_sha: "landed")
  end
  let(:clone) { instance_double(RepositoryBareClone, path: Pathname.new("/tmp/repo.git"), sync!: true) }
  let(:git) { instance_double(GitRunner) }

  before do
    LandedCommit.create!(landable: original, sha: "commit-a", kind: "implementation", position: 0)
    allow(RepositoryBareClone).to receive(:new).and_return(clone)
    allow(clone).to receive(:read_from_default_branch).and_return(nil)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).with("rev-parse", "refs/heads/#{original.repository.default_branch}", anything).and_return("base\n")
    allow(git).to receive(:run).with("merge-base", "--is-ancestor", "commit-a", "base", anything).and_return("")
    allow(git).to receive(:run).with("rev-list", "--parents", "-n", "1", "commit-a", anything)
      .and_return("commit-a parent-a\n")
    allow(git).to receive(:run).with("diff-tree", "--no-commit-id", "--name-only", "-r", anything, anything)
      .and_return("app/models/example.rb\n")
    allow(WorkUnits::Launcher).to receive(:start!)
  end

  it "creates a linked rollback Job without changing the original landing facts" do
    rollback = described_class.call!(original: original)

    expect(rollback.rollback_of).to eq(original)
    expect(rollback.workflows.last).to have_attributes(trigger_kind: "unland")
    expect(rollback.workflows.last.artifact("unland_commit_shas")).to eq([ "commit-a" ])
    expect(original.reload).to have_attributes(state: "closed", closure_reason: "pr_merged", landed_sha: "landed")
    expect(rollback.workflows.last.artifact("unland_plan")).to include(
      "subject" => original.slug, "files" => [ "app/models/example.rb" ]
    )
  end

  it "rejects a duplicate active rollback" do
    Factories.job_record(repository: original.repository, user: original.user, rollback_of: original, state: "running")

    expect { described_class.call!(original: original) }
      .to raise_error(described_class::Ineligible, /already active/)
  end

  it "rejects a successfully landed rollback" do
    Factories.job_record(
      repository: original.repository, user: original.user, rollback_of: original,
      state: "closed", closure_reason: "pr_merged", landed_sha: "rollback-landed"
    )

    expect { described_class.call!(original: original) }
      .to raise_error(described_class::Ineligible, /already successfully unlanded/)
  end

  it "rejects unverifiable landed ancestry" do
    allow(git).to receive(:run).with("merge-base", "--is-ancestor", "commit-a", "base", anything)
      .and_raise(GitRunner::GitError.new([], 1, "not ancestor"))

    expect { described_class.call!(original: original) }
      .to raise_error(described_class::Ineligible, /not safely reachable/)
  end

  it "rejects merge commits whose rollback mainline is ambiguous" do
    allow(git).to receive(:run).with("rev-list", "--parents", "-n", "1", "commit-a", anything)
      .and_return("commit-a parent-a parent-b\n")

    expect { described_class.call!(original: original) }
      .to raise_error(described_class::Ineligible, /ambiguous rollback mainline/)
  end

  it "rejects a landing with no recorded commits" do
    LandedCommit.where(landable: original).delete_all

    expect { described_class.call!(original: original) }
      .to raise_error(described_class::Ineligible, /landed commits are missing/)
  end

  it "permits a fresh attempt after a failed rollback" do
    Factories.job_record(repository: original.repository, user: original.user, rollback_of: original, state: "failed")

    expect { described_class.call!(original: original) }.to change(original.rollback_jobs, :count).by(1)
  end

  context "with a landed Epic" do
    let(:epic) { Factories.epic(user: original.user, repository: original.repository, state: "done") }
    let!(:first) do
      Factories.job_record(
        user: original.user, repository: original.repository, epic: epic,
        state: "closed", closure_reason: "pr_merged", landed_sha: "first-landed"
      )
    end
    let!(:second) do
      Factories.job_record(
        user: original.user, repository: original.repository, epic: epic,
        state: "closed", closure_reason: "pr_merged", landed_sha: "second-landed"
      )
    end

    before do
      first.update_column(:epic_id, epic.id)
      second.update_column(:epic_id, epic.id)
      LandedCommit.create!(landable: first, sha: "first-commit", kind: "implementation", position: 0)
      LandedCommit.create!(landable: second, sha: "second-commit", kind: "implementation", position: 0)
      epic.update_column(:state, "done")
      epic.reload
      %w[first-commit second-commit].each do |sha|
        allow(git).to receive(:run).with("merge-base", "--is-ancestor", sha, "base", anything).and_return("")
        allow(git).to receive(:run).with("rev-list", "--parents", "-n", "1", sha, anything).and_return("#{sha} parent\n")
      end
    end

    it "plans and creates one coordinated rollback while preserving every child closure" do
      plan = described_class.plan!(original: epic)
      rollback = described_class.call!(original: epic)

      expect(plan.commit_shas).to eq(%w[first-commit second-commit])
      expect(plan.affected).to contain_exactly(epic.slug, first.slug, second.slug)
      expect(rollback).to have_attributes(rollback_epic: epic, rollback_of: nil)
      expect(rollback.workflows.last.artifact("unland_commit_shas")).to eq(%w[first-commit second-commit])
      expect(first.reload).to have_attributes(state: "closed", landed_sha: "first-landed")
      expect(second.reload).to have_attributes(state: "closed", landed_sha: "second-landed")

      rollback.update_columns(state: "closed", closure_reason: "pr_merged", landed_sha: "rollback-landed")
      expect(epic.unlanded_by).to eq(rollback)
    end

    it "uses merge-train membership order and includes reconciliation without reverting unrelated history" do
      train = MergeTrain.create!(epic: epic, repository: epic.repository, base_branch: "main", state: "succeeded")
      MergeTrainMember.create!(merge_train: train, job: second, position: 0, state: "merged")
      MergeTrainMember.create!(merge_train: train, job: first, position: 1, state: "merged")
      LandedCommit.create!(landable: epic, sha: "reconcile", kind: "reconcile", position: 0)
      allow(git).to receive(:run).with("merge-base", "--is-ancestor", "reconcile", "base", anything).and_return("")
      allow(git).to receive(:run).with("rev-list", "--parents", "-n", "1", "reconcile", anything).and_return("reconcile parent\n")

      expect(described_class.plan!(original: epic).commit_shas)
        .to eq(%w[second-commit first-commit reconcile])
    end

    it "rejects partial landing and a previously reverted child before creating mutable work" do
      second.update!(state: "implemented", closure_reason: nil)
      expect { described_class.call!(original: epic) }.to raise_error(described_class::Ineligible, /partial or mixed/)
      expect(epic.rollback_jobs).to be_empty

      second.update!(state: "closed", closure_reason: "pr_merged")
      Factories.job_record(
        user: first.user, repository: first.repository, rollback_of: first,
        state: "closed", closure_reason: "pr_merged", landed_sha: "revert"
      )
      expect { described_class.call!(original: epic) }.to raise_error(described_class::Ineligible, /previously reverted/)
    end

    it "rejects shared commit ownership" do
      LandedCommit.where(landable: second).delete_all
      LandedCommit.create!(landable: second, sha: "first-commit", kind: "implementation", position: 0)

      expect { described_class.plan!(original: epic) }
        .to raise_error(described_class::Ineligible, /shared commit ownership/)
    end
  end
end
