require "rails_helper"

RSpec.describe Steps::PublishSourceSnapshot do
  let(:job) { Factories.job_record(state: "running") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "base_refresh_retry", state: "running") }
  let(:step) { Step.create!(workflow: workflow, kind: "publish_source_snapshot", position: 0, state: "running") }
  let(:run) { step.runs.create!(job: job, user: job.user, trigger_kind: workflow.trigger_kind, agent_provider: "claude", state: "running") }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: true, path: Pathname.new("/tmp/refreshed-workspace")) }
  let(:git) { instance_double(GitRunner) }

  it "publishes and records the refreshed immutable source" do
    handler = described_class.new(run)
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:head_sha).and_return("refreshed-sha")
    allow(GitRunner).to receive(:new).and_return(git)
    allow(GithubAuthenticatedGit).to receive(:run) { |**_kwargs, &block| block.call("https://example.test/repo.git") }
    allow(git).to receive(:run).with("push", anything,
      "refreshed-sha:refs/syrus/source-snapshots/runs/#{run.id}", chdir: workspace.path.to_s,
      env: { "GIT_TERMINAL_PROMPT" => "0" })
    allow(git).to receive(:run).with("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).and_return("tree-sha\n")

    expect { handler.call }.to change(WorkflowSourceSnapshot, :count).by(1)
    snapshot = workflow.source_snapshots.sole
    expect(snapshot).to have_attributes(source_sha: "refreshed-sha", tree_sha: "tree-sha", creator_step: step)
    expect(workflow.reload.artifact("base_refresh_source_snapshot_id")).to eq(snapshot.id)
  end
end
