require "rails_helper"

RSpec.describe RunCheckpointPublisher do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "running") }
  let(:workflow) { Workflows::Initial.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "implement") }
  let(:run) do
    step.runs.create!(
      job: job,
      user: user,
      trigger_kind: workflow.trigger_kind,
      agent_provider: "claude",
      state: "succeeded",
      head_sha: "abc123",
      base_sha: "base123"
    )
  end
  let(:workspace) { instance_double(WorkflowWorkspace, path: Pathname.new("/tmp/workspace")) }
  let(:git) { instance_double(GitRunner) }

  before do
    allow(GithubAuthenticatedGit).to receive(:run) do |**_kwargs, &block|
      block.call("https://example.test/repo.git")
    end
  end

  it "publishes a successful mutation run to an immutable hidden ref" do
    allow(git).to receive(:run).with("ls-remote", "https://example.test/repo.git", "refs/syrus/checkpoints/runs/#{run.id}", chdir: "/tmp/workspace", env: { "GIT_TERMINAL_PROMPT" => "0" }).and_return("")
    allow(git).to receive(:run).with("push", "https://example.test/repo.git", "abc123:refs/syrus/checkpoints/runs/#{run.id}", chdir: "/tmp/workspace", env: { "GIT_TERMINAL_PROMPT" => "0" }).and_return("")

    checkpoint = described_class.publish!(run: run, workspace: workspace, git: git)

    expect(checkpoint).to be_published
    expect(checkpoint).to have_attributes(
      run: run,
      workflow: workflow,
      step: step,
      job: job,
      repository: repository,
      user: user,
      step_kind: "implement",
      commit_sha: "abc123",
      base_sha: "base123",
      remote_ref: "refs/syrus/checkpoints/runs/#{run.id}"
    )
  end

  it "does not push again when the immutable ref already points at the same SHA" do
    allow(git).to receive(:run).with("ls-remote", anything, anything, any_args).and_return("abc123\trefs/syrus/checkpoints/runs/#{run.id}\n")
    expect(git).not_to receive(:run).with("push", anything, anything, any_args)

    checkpoint = described_class.publish!(run: run, workspace: workspace, git: git)

    expect(checkpoint).to be_published
  end

  it "records failure when the immutable ref points at a different SHA" do
    allow(git).to receive(:run).with("ls-remote", anything, anything, any_args).and_return("def456\trefs/syrus/checkpoints/runs/#{run.id}\n")

    expect(described_class.publish!(run: run, workspace: workspace, git: git)).to be_nil
    checkpoint = run.reload.run_checkpoint
    expect(checkpoint.status).to eq("failed")
    expect(checkpoint.error_message).to include("already points at def456")
  end

  it "records a sanitized failure when GitHub push protection rejects the checkpoint" do
    finding = GithubPushProtection::Finding.new(secret_type: "Token", commit_sha: "a" * 40, path: "x.rb", line: 2)
    rejected = GithubPushProtection::Rejected.new([ "push", "u", "abc123:refs/syrus/checkpoints/runs/#{run.id}" ], 1, findings: [ finding ], ref: "refs/x")
    allow(git).to receive(:run).with("ls-remote", anything, anything, any_args).and_return("")
    allow(git).to receive(:run).with("push", anything, anything, any_args).and_raise(rejected)

    expect(described_class.publish!(run: run, workspace: workspace, git: git)).to be_nil

    checkpoint = run.reload.run_checkpoint
    expect(checkpoint.status).to eq("failed")
    expect(checkpoint.error_message).to include("push protection").and include("x.rb:2")
    expect(PushProtection::Ledger.for(workflow).clean_anchor).to be_nil
  end

  it "advances the clean anchor only after the checkpoint push succeeds" do
    allow(git).to receive(:run).with("ls-remote", anything, anything, any_args).and_return("")
    allow(git).to receive(:run).with("push", anything, anything, any_args).and_return("")

    described_class.publish!(run: run, workspace: workspace, git: git)

    expect(PushProtection::Ledger.for(workflow).clean_anchor).to eq("abc123")
  end
end
