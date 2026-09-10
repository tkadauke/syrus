require "rails_helper"

RSpec.describe Steps::PushAgentRebase do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) do
    Factories.job(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 9,
      branch_name: "syrus/issue-42"
    )
  end
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "pr_comment", agent_provider: "claude") }
  let(:step) { Step.create!(workflow: workflow, kind: "push_agent_rebase", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "pr_comment", agent_provider: "claude") }
  let(:handler) { described_class.new(run) }
  let(:workspace) do
    instance_double(
      WorkflowWorkspace,
      setup: nil,
      branch_name: "syrus/issue-42",
      path: Pathname.new("/tmp/workspace")
    )
  end
  let(:git) { instance_double(GitRunner) }
  let(:client) { instance_double(GithubClient, access_token: "token") }
  let(:push_url) { "https://push.example/repo.git" }
  let(:remote_ref) { "refs/remotes/origin/syrus/issue-42" }

  before do
    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:active_installation_for).and_return(nil)
    allow(GithubClient).to receive(:for).with(repository: kind_of(Repository), user: user).and_return(client)
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).with("token").and_return(push_url)
  end

  it "uses a clean deterministic rebase result without invoking the agent" do
    allow(handler).to receive(:head_sha).and_return("a" * 40, "b" * 40)
    expect(handler).not_to receive(:run_agent)

    expect(git).to receive(:run).with(
      "fetch", push_url, "+refs/heads/syrus/issue-42:#{remote_ref}",
      chdir: "/tmp/workspace"
    ).ordered
    expect(git).to receive(:run).with("rev-parse", remote_ref, chdir: "/tmp/workspace").ordered.and_return("#{"c" * 40}\n")
    expect(git).to receive(:run).with("rebase", remote_ref, chdir: "/tmp/workspace").ordered
    expect_clean_rebase_verification

    handler.call

    expect(workflow.reload.artifact("push_rebase_remote_ref")).to eq(remote_ref)
    expect(workflow.artifact("push_rebase_remote_sha")).to eq("c" * 40)
    expect(workflow.artifact("push_rebase_resolved_head_sha")).to eq("b" * 40)
    expect(run.reload.head_sha).to eq("b" * 40)
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("deterministic retry rebased cleanly")
  end

  it "invokes the agent to resolve a conflicting deterministic rebase" do
    allow(handler).to receive(:head_sha).and_return("a" * 40, "d" * 40)
    rebase_error = GitRunner::GitError.new(
      [ "rebase", remote_ref ],
      1,
      "CONFLICT (content): Merge conflict"
    )

    expect(git).to receive(:run).with(
      "fetch", push_url, "+refs/heads/syrus/issue-42:#{remote_ref}",
      chdir: "/tmp/workspace"
    ).ordered
    expect(git).to receive(:run).with("rev-parse", remote_ref, chdir: "/tmp/workspace").ordered.and_return("#{"c" * 40}\n")
    expect(git).to receive(:run).with("rebase", remote_ref, chdir: "/tmp/workspace").ordered.and_raise(rebase_error)
    expect(handler).to receive(:run_agent) do |prompt:|
      expect(prompt).to include("acme/widgets#9")
      expect(prompt).to include("syrus/issue-42")
      expect(prompt).to include(remote_ref)
    end
    expect_clean_rebase_verification

    handler.call

    expect(run.reload.prompt).to include("remote PR branch advanced")
    expect(run.head_sha).to eq("d" * 40)
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("invoking agent for push_agent_rebase")
  end

  it "fails if the agent leaves the rebase in progress" do
    allow(handler).to receive(:head_sha).and_return("a" * 40)
    rebase_error = GitRunner::GitError.new(
      [ "rebase", remote_ref ],
      1,
      "CONFLICT (content): Merge conflict"
    )

    allow(git).to receive(:run).with(
      "fetch", push_url, "+refs/heads/syrus/issue-42:#{remote_ref}",
      chdir: "/tmp/workspace"
    )
    allow(git).to receive(:run).with("rev-parse", remote_ref, chdir: "/tmp/workspace").and_return("#{"c" * 40}\n")
    allow(git).to receive(:run).with("rebase", remote_ref, chdir: "/tmp/workspace").and_raise(rebase_error)
    allow(handler).to receive(:run_agent)
    allow(git).to receive(:run).with("rev-parse", "--git-path", "rebase-merge", chdir: "/tmp/workspace").and_return(".git/rebase-merge\n")
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(Pathname.new("/tmp/workspace/.git/rebase-merge")).and_return(true)

    expect { handler.call }.to raise_error(
      Steps::Base::StepFailed,
      "push_agent_rebase: rebase is still in progress; run git rebase --continue until it completes"
    )

    expect(run.reload.head_sha).to be_nil
  end

  def expect_clean_rebase_verification
    expect(git).to receive(:run).with("rev-parse", "--git-path", "rebase-merge", chdir: "/tmp/workspace").ordered.and_return(".git/rebase-merge\n")
    expect(git).to receive(:run).with("rev-parse", "--git-path", "rebase-apply", chdir: "/tmp/workspace").ordered.and_return(".git/rebase-apply\n")
    expect(git).to receive(:run).with("status", "--porcelain", chdir: "/tmp/workspace").ordered.and_return("")
    expect(git).to receive(:run).with("merge-base", "--is-ancestor", remote_ref, "HEAD", chdir: "/tmp/workspace").ordered
  end
end
