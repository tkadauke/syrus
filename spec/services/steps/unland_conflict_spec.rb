require "rails_helper"

RSpec.describe Steps::UnlandConflict do
  let(:original) do
    Factories.job_record(state: "closed", closure_reason: "pr_merged", landed_sha: "landed")
  end
  let(:job) { Factories.job_record(repository: original.repository, user: original.user, rollback_of: original) }
  let(:workflow) do
    Workflows::Unland.instantiate(job: job, artifacts: { "unland_commit_shas" => %w[first second third] })
  end
  let(:step) { workflow.steps.find_by!(kind: "unland_conflict") }
  let(:run) do
    step.runs.create!(job: job, user: job.user, trigger_kind: workflow.trigger_kind,
      agent_provider: workflow.agent_provider, state: "running")
  end
  let(:path) { Pathname.new(Dir.mktmpdir("unland-conflict")) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: true, path: path) }
  let(:git) { instance_double(GitRunner) }
  subject(:handler) { described_class.new(run) }

  before do
    FileUtils.mkdir_p(path.join(".git"))
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:perform_agentic_change_step)
    allow(GitRunner).to receive(:new).and_return(git)
    allow(git).to receive(:run).with("rev-parse", "--git-path", "REVERT_HEAD", chdir: path.to_s)
      .and_return(".git/REVERT_HEAD\n")
  end

  after { FileUtils.rm_rf(path) }

  it "tells the agent to continue the complete reverse-order sequence" do
    handler.call

    expect(run.reload.prompt).to include("- third\n- second\n- first")
    expect(run.prompt).to include("git revert --continue")
  end

  it "fails instead of grading when conflict resolution leaves the sequencer active" do
    FileUtils.touch(path.join(".git/REVERT_HEAD"))

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /left a revert in progress/)
  end
end
