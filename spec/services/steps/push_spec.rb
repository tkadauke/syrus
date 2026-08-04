require "rails_helper"

RSpec.describe Steps::Push do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repository, issue_number: 42, pr_number: 9) }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "pr_comment", agent_provider: "claude") }
  let(:step) { Step.create!(workflow: workflow, kind: "push", position: 0) }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "pr_comment", agent_provider: "claude") }

  it "replaces the managed PR cost footer after follow-up pushes" do
    job.initial_run.update!(cost_usd: 0.10)
    run.update!(cost_usd: 0.20)
    client = instance_double(GithubClient, access_token: "ghp_test")
    existing_body = PrCostFooter.apply("Original body", job)

    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(client).to receive(:pull_request)
      .with("acme/widgets", 9, bypass_cache: true)
      .and_return(Struct.new(:body).new(existing_body))

    expect(client).to receive(:update_pull_request_body) do |slug, pr_number, body|
      expect(slug).to eq("acme/widgets")
      expect(pr_number).to eq(9)
      expect(body.scan("This PR was implemented by Syrus").size).to eq(1)
      expect(body).to include("across 2 Runs at a total cost of $0.30")
    end

    described_class.new(run).send(:update_managed_pr_footers)
  end

  it "does not re-fetch and rewrite PR footers after applying refreshed metadata" do
    handler = described_class.new(run)

    allow(handler).to receive(:workspace).and_return(instance_double(
      WorkflowWorkspace,
      setup: nil,
      branch_name: "syrus/issue-42",
      path: Pathname.new("/tmp/workspace")
    ))
    git = instance_double(GitRunner)
    client = instance_double(GithubClient, access_token: "token")
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)
    allow(JobMetadataRefreshApplier).to receive(:new).with(workflow).and_return(instance_double(JobMetadataRefreshApplier, call: "applied refreshed Job metadata"))
    workflow.set_artifact!("job_metadata_applied", { "changed" => true })

    expect(handler).not_to receive(:update_managed_pr_footers)

    handler.call
  end

  it "skips publication for manual agentic runs with push disabled" do
    workflow.update!(trigger_kind: "manual_agentic_run")
    workflow.set_artifact!("manual_agentic_run_push", false)
    handler = described_class.new(run)

    allow(handler).to receive(:workspace).and_return(instance_double(
      WorkflowWorkspace,
      setup: nil,
      branch_name: "syrus/issue-42",
      path: Pathname.new("/tmp/workspace")
    ))

    expect(handler).not_to receive(:streaming_git)
    handler.call
  end

  it "rebases onto the remote branch and retries when a follow-up push is not a fast-forward" do
    job.update!(branch_name: "syrus/issue-42")
    handler = described_class.new(run)
    workspace = instance_double(
      WorkflowWorkspace,
      setup: nil,
      branch_name: "syrus/issue-42",
      path: Pathname.new("/tmp/workspace")
    )
    git = instance_double(GitRunner)
    client = instance_double(GithubClient, access_token: "token")
    push_url = "https://push.example/repo.git"
    push_error = GitRunner::GitError.new(
      [ "push", push_url, "HEAD:refs/heads/syrus/issue-42" ],
      1,
      "! [rejected] HEAD -> syrus/issue-42 (fetch first)"
    )

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(repository).to receive(:authenticated_push_url).with("token").and_return(push_url)
    allow(handler).to receive(:update_managed_pr_footers)

    expect(git).to receive(:run).with(
      "push", push_url, "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).ordered.and_raise(push_error)
    expect(git).to receive(:run).with(
      "fetch", push_url, "+refs/heads/syrus/issue-42:refs/remotes/origin/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).ordered
    expect(git).to receive(:run).with(
      "rev-parse", "refs/remotes/origin/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).ordered.and_return("remote123\n")
    expect(git).to receive(:run).with(
      "rebase", "refs/remotes/origin/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).ordered
    expect(git).to receive(:run).with(
      "push", push_url, "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).ordered

    handler.call

    expect(workflow.reload.artifact("push_rebase_remote_ref")).to eq("refs/remotes/origin/syrus/issue-42")
    expect(workflow.artifact("push_rebase_remote_sha")).to eq("remote123")
    expect(workflow.artifact("push_rebase_branch")).to eq("syrus/issue-42")
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("remote branch advanced")
  end

  it "fails with a clear message when automatic rebase after a rejected push conflicts" do
    job.update!(branch_name: "syrus/issue-42")
    handler = described_class.new(run)
    workspace = instance_double(
      WorkflowWorkspace,
      setup: nil,
      branch_name: "syrus/issue-42",
      path: Pathname.new("/tmp/workspace")
    )
    git = instance_double(GitRunner)
    client = instance_double(GithubClient, access_token: "token")
    push_url = "https://push.example/repo.git"
    push_error = GitRunner::GitError.new(
      [ "push", push_url, "HEAD:refs/heads/syrus/issue-42" ],
      1,
      "! [rejected] HEAD -> syrus/issue-42 (fetch first)"
    )
    rebase_error = GitRunner::GitError.new(
      [ "rebase", "refs/remotes/origin/syrus/issue-42" ],
      1,
      "CONFLICT (content): Merge conflict"
    )

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
    allow(repository).to receive(:authenticated_push_url).with("token").and_return(push_url)

    allow(git).to receive(:run).with(
      "push", push_url, "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).and_raise(push_error)
    allow(git).to receive(:run).with(
      "fetch", push_url, "+refs/heads/syrus/issue-42:refs/remotes/origin/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
    allow(git).to receive(:run).with(
      "rev-parse", "refs/remotes/origin/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).and_return("remote123\n")
    allow(git).to receive(:run).with(
      "rebase", "refs/remotes/origin/syrus/issue-42",
      chdir: "/tmp/workspace"
    ).and_raise(rebase_error)
    allow(git).to receive(:run).with("rebase", "--abort", chdir: "/tmp/workspace")

    expect { handler.call }.to raise_error(Steps::Push::RemoteBranchAdvancedRebaseConflict, /automatic rebase failed/)
    expect(step.reload.details).to include("failure_code" => "remote_branch_advanced_rebase_conflict")
    expect(workflow.reload.artifact("push_rebase_remote_ref")).to eq("refs/remotes/origin/syrus/issue-42")
  end
end
