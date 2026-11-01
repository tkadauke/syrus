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
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).with("rev-parse", "refs/heads/#{original.repository.default_branch}", anything).and_return("base\n")
    allow(git).to receive(:run).with("merge-base", "--is-ancestor", "commit-a", "base", anything).and_return("")
    allow(git).to receive(:run).with("rev-list", "--parents", "-n", "1", "commit-a", anything)
      .and_return("commit-a parent-a\n")
    allow(WorkUnits::Launcher).to receive(:start!)
  end

  it "creates a linked rollback Job without changing the original landing facts" do
    rollback = described_class.call!(original: original)

    expect(rollback.rollback_of).to eq(original)
    expect(rollback.workflows.last).to have_attributes(trigger_kind: "unland")
    expect(rollback.workflows.last.artifact("unland_commit_shas")).to eq([ "commit-a" ])
    expect(original.reload).to have_attributes(state: "closed", closure_reason: "pr_merged", landed_sha: "landed")
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
end
