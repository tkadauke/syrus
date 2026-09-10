require "rails_helper"

RSpec.describe Steps::StackAgentRebase do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "main") }
  let(:job) do
    Factories.job(
      user: user,
      repository: repository,
      issue_number: 42,
      pr_number: 7,
      branch_name: "syrus/issue-42-1"
    )
  end
  let!(:child) do
    Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 43,
      pr_number: 8,
      branch_name: "syrus/issue-43-2",
      parent_job: job
    )
  end
  let(:workflow) { Workflows::StackRebase.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "stack_agent_rebase") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "stack_rebase") }

  it "detaches before resetting pending stack branches for an agent stack rebase retry" do
    workflow.set_artifact!(
      StackRebasePlan::AGENT_PENDING_ARTIFACT,
      workflow.artifact(StackRebasePlan::STACK_ARTIFACT)
    )
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace, path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)
    push_url = "https://push.example/repo.git"

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:active_installation_for).and_return(nil)
    allow(GithubClient).to receive(:for)
      .with(repository: kind_of(Repository), user: user)
      .and_return(instance_double(GithubClient, access_token: "token"))
    allow_any_instance_of(Repository).to receive(:authenticated_push_url).with("token").and_return(push_url)
    allow(git).to receive(:run).and_return("")
    handler.send(:fetch_pending_branches)

    expect(git).not_to have_received(:run).with(
      "fetch",
      push_url,
      "refs/heads/#{job.branch_name}:refs/heads/#{job.branch_name}",
      chdir: "/tmp/workspace"
    )
    expect(git).to have_received(:run).with(
      "fetch",
      push_url,
      "refs/heads/#{job.branch_name}:refs/remotes/origin/#{job.branch_name}",
      chdir: "/tmp/workspace"
    )
    expect(git).to have_received(:run).with("checkout", "--detach", "HEAD", chdir: "/tmp/workspace")
    expect(git).to have_received(:run).with(
      "branch",
      "-f",
      job.branch_name,
      "refs/remotes/origin/#{job.branch_name}",
      chdir: "/tmp/workspace"
    )
    expect(git).to have_received(:run).with(
      "branch",
      "-f",
      child.branch_name,
      "refs/remotes/origin/#{child.branch_name}",
      chdir: "/tmp/workspace"
    )
    expect(git).to have_received(:run).with("checkout", job.branch_name, chdir: "/tmp/workspace")
  end
end
