require "rails_helper"

RSpec.describe Steps::BaseRefreshRebase do
  let(:job) { Factories.job_record(state: "queued", branch_name: nil) }
  let(:workflow) do
    Workflows::BaseRefreshRetry.instantiate(job: job, artifacts: {
      "checkpoint_ref" => "refs/syrus/checkpoints/runs/10", "checkpoint_sha" => "checkpoint-sha",
      RebaseTarget::BRANCH_ARTIFACT => "syrus/issue-42-1",
      RebaseTarget::BASE_BRANCH_ARTIFACT => "main", RebaseTarget::BASE_SHA_ARTIFACT => "base-sha"
    })
  end
  let(:step) { workflow.steps.find_by!(kind: "base_refresh_rebase") }
  let(:run) { step.runs.create!(job: job, user: job.user, trigger_kind: workflow.trigger_kind, agent_provider: "claude", state: "running") }
  let(:path) { Pathname.new(Dir.mktmpdir) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: true, path: path) }
  let(:git) { instance_double(GitRunner) }
  subject(:handler) { described_class.new(run) }

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:git).and_return(git)
    allow(GithubAuthenticatedGit).to receive(:run) { |**_kwargs, &block| block.call("https://example.test/repo.git") }
    allow(git).to receive(:run).with("fetch", anything, "refs/heads/main", chdir: path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: path.to_s).and_return("base-sha\n")
  end

  after { FileUtils.rm_rf(path) }

  it "skips agent repair after a clean mechanical rebase" do
    allow(handler).to receive(:head_sha).and_return("checkpoint-sha", "checkpoint-sha", "rebased-sha")
    allow(git).to receive(:run).with("rebase", "base-sha", chdir: path.to_s)
    handler.call
    expect(step.next_step.reload).to be_skipped
    expect(workflow.reload.artifact("base_refresh_rebase_result")).to include("status" => "rebased")
  end

  it "keeps the bounded agent step runnable for branchless conflicts" do
    allow(handler).to receive(:head_sha).and_return("checkpoint-sha", "checkpoint-sha")
    FileUtils.mkdir_p(path.join(".git/rebase-merge"))
    allow(git).to receive(:run).with("rebase", "base-sha", chdir: path.to_s)
      .and_raise(GitRunner::GitError.new([ "rebase" ], 1, "conflict"))
    handler.call
    expect(step.next_step.reload).to be_queued
    expect(workflow.reload.artifact("base_refresh_rebase_result")).to include("status" => "conflict")
    prompt = Steps::AgentRebase.new(step.next_step.runs.build(job: job, user: job.user,
      trigger_kind: workflow.trigger_kind, agent_provider: "claude")).send(:compose_prompt)
    expect(prompt).to include("unpublished work on branch `syrus/issue-42-1`")
  end

  it "fails safely before rebasing a stale checkpoint" do
    allow(handler).to receive(:head_sha).and_return("unexpected-sha")
    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /checkpoint mismatch/)
    expect(git).not_to have_received(:run).with("rebase", anything, any_args)
  end
end
