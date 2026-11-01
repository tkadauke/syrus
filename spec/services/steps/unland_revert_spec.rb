require "rails_helper"

RSpec.describe Steps::UnlandRevert do
  let(:original) do
    Factories.job_record(state: "closed", closure_reason: "pr_merged", landed_sha: "landed")
  end
  let(:job) { Factories.job_record(repository: original.repository, user: original.user, rollback_of: original) }
  let(:workflow) do
    Workflows::Unland.instantiate(job: job, artifacts: {
      "unland_base_sha" => "base-sha", "unland_commit_shas" => %w[first second third]
    })
  end
  let(:step) { workflow.steps.find_by!(kind: "unland_revert") }
  let(:run) do
    step.runs.create!(job: job, user: job.user, trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider, state: "running")
  end
  let(:path) { Pathname.new(Dir.mktmpdir("unland-revert")) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: true, path: path, base_ref: "origin/main") }
  let(:git) { instance_double(GitRunner) }
  subject(:handler) { described_class.new(run) }

  before do
    FileUtils.mkdir_p(path.join(".git"))
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).with("rev-parse", "origin/main^{commit}", chdir: path.to_s).and_return("base-sha\n")
    allow(git).to receive(:run).with("rev-parse", "--git-path", "REVERT_HEAD", chdir: path.to_s)
      .and_return(".git/REVERT_HEAD\n")
    allow(handler).to receive(:head_sha).and_return("rollback-sha")
    allow(handler).to receive(:commit_agent_changes)
  end

  after { FileUtils.rm_rf(path) }

  it "reverses every commit in one reverse-order sequencer operation" do
    allow(git).to receive(:run).with(
      "revert", "--no-commit", "third", "second", "first", chdir: path.to_s
    )

    handler.call

    expect(handler).to have_received(:commit_agent_changes).with("Rollback #{original.slug}")
    expect(workflow.reload.artifact("unland_conflict")).to be(false)
    expect(workflow.steps.find_by!(kind: "unland_conflict")).to be_skipped
  end

  it "preserves the sequencer and leaves conflict resolution runnable" do
    allow(git).to receive(:run).with(
      "revert", "--no-commit", "third", "second", "first", chdir: path.to_s
    ) do
      FileUtils.touch(path.join(".git/REVERT_HEAD"))
      raise GitRunner::GitError.new([ "revert" ], 1, "conflict")
    end

    handler.call

    expect(handler).not_to have_received(:commit_agent_changes)
    expect(workflow.reload.artifact("unland_conflict")).to be(true)
    expect(workflow.steps.find_by!(kind: "unland_conflict")).to be_queued
  end

  it "reuses an in-progress sequencer operation on retry" do
    FileUtils.touch(path.join(".git/REVERT_HEAD"))

    handler.call

    expect(git).not_to have_received(:run).with("revert", any_args)
    expect(workflow.reload.artifact("unland_conflict")).to be(true)
  end

  it "fails when the default branch moved before construction" do
    allow(git).to receive(:run).with("rev-parse", "origin/main^{commit}", chdir: path.to_s).and_return("new-base\n")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /default branch moved/)
  end

  it "does not route a non-conflict git failure to the agent" do
    allow(git).to receive(:run).with(
      "revert", "--no-commit", "third", "second", "first", chdir: path.to_s
    ).and_raise(GitRunner::GitError.new([ "revert" ], 1, "empty"))

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /without a resolvable conflict/)
    expect(workflow.reload.artifact("unland_conflict")).to be_nil
  end
end
