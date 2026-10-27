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
    revision = RepositoryContent::Revision.new(id: "base-sha", ref: "main", observed_at: Time.current)
    reader = instance_double(RepositoryContent::Reader, resolve: revision)
    allow(RepositoryContent).to receive(:for).and_return(reader)
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
    expect(RepositoryContent).not_to have_received(:for)
    expect(git).not_to have_received(:run).with("rebase", anything, any_args)
  end

  it "refreshes a stale enqueue-time base pin and rebases onto the current base" do
    revision = RepositoryContent::Revision.new(id: "current-base-sha", ref: "main", observed_at: Time.current)
    allow(RepositoryContent).to receive(:for).and_return(instance_double(RepositoryContent::Reader, resolve: revision))
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: path.to_s).and_return("current-base-sha\n")
    allow(handler).to receive(:head_sha).and_return("checkpoint-sha", "checkpoint-sha", "rebased-sha")
    allow(handler).to receive(:log)
    allow(git).to receive(:run).with("rebase", "current-base-sha", chdir: path.to_s)

    handler.call

    expect(handler).to have_received(:log).with(/stale base pin: main was base-sha at enqueue, refreshing to current-base-sha/)
    expect(workflow.reload.artifact(RebaseTarget::BASE_SHA_ARTIFACT)).to eq("current-base-sha")
    expect(workflow.artifact("base_refresh_rebase_result")).to include(
      "status" => "rebased", "checkpoint_sha" => "checkpoint-sha", "base_sha" => "current-base-sha"
    )
  end

  it "distinguishes a start-time race from a stale enqueue-time pin" do
    revision = RepositoryContent::Revision.new(id: "resolved-base-sha", ref: "main", observed_at: Time.current)
    allow(RepositoryContent).to receive(:for).and_return(instance_double(RepositoryContent::Reader, resolve: revision))
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: path.to_s).and_return("raced-base-sha\n")
    allow(handler).to receive(:head_sha).and_return("checkpoint-sha")

    expect { handler.call }.to raise_error(
      Steps::Base::StepFailed,
      /moved during base refresh startup: main resolved to resolved-base-sha immediately before fetch, but fetch returned raced-base-sha/
    )
    expect(git).not_to have_received(:run).with("rebase", anything, any_args)
    expect(workflow.reload.artifact(RebaseTarget::BASE_SHA_ARTIFACT)).to eq("base-sha")
  end
end
