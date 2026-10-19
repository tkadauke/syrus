require "rails_helper"

RSpec.describe Steps::BaseRefreshRebase do
  let(:job) { Factories.job_record(state: "failed") }
  let(:workflow) do
    Workflows::BaseRefreshRetry.instantiate(
      job: job,
      artifacts: {
        "checkpoint_ref" => "refs/syrus/checkpoints/runs/10",
        "checkpoint_sha" => "checkpoint-sha",
        RebaseTarget::BASE_BRANCH_ARTIFACT => "main",
        RebaseTarget::BASE_SHA_ARTIFACT => "base-sha"
      }
    )
  end
  let(:step) { workflow.steps.find_by!(kind: "base_refresh_rebase") }
  let(:run) do
    step.runs.create!(job: job, user: job.user, trigger_kind: workflow.trigger_kind,
                      agent_provider: "claude", state: "running")
  end
  let(:workspace) { instance_double(WorkflowWorkspace, setup: true, path: Pathname.new(Dir.mktmpdir)) }
  let(:git) { instance_double(GitRunner) }
  subject(:handler) { described_class.new(run) }

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:head_sha).and_return("checkpoint-sha", "checkpoint-sha", "rebased-sha")
    allow(handler).to receive(:git).and_return(git)
    allow(GithubAuthenticatedGit).to receive(:run) { |**_kwargs, &block| block.call("https://example.test/repo.git") }
    allow(git).to receive(:run)
      .with("fetch", anything, "refs/heads/main", chdir: workspace.path.to_s, env: { "GIT_TERMINAL_PROMPT" => "0" })
    allow(git).to receive(:run).with("rev-parse", "FETCH_HEAD", chdir: workspace.path.to_s).and_return("base-sha\n")
  end

  after { FileUtils.rm_rf(workspace.path) }

  it "mechanically rebases the checkpoint onto the pinned SHA and skips agent repair" do
    allow(git).to receive(:run).with("rebase", "base-sha", chdir: workspace.path.to_s).and_return("")

    handler.call

    expect(workflow.reload.artifact("base_refresh_rebase_result")).to include(
      "status" => "rebased", "pre_sha" => "checkpoint-sha", "post_sha" => "rebased-sha"
    )
    expect(step.next_step.reload).to be_skipped
  end

  it "fails before rebasing when the restored checkpoint does not match provenance" do
    allow(handler).to receive(:head_sha).and_return("stale-sha")

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /checkpoint mismatch/)
    expect(git).not_to have_received(:run).with("rebase", anything, any_args)
  end
end
