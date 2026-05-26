require "rails_helper"

RSpec.describe Steps::ForcePush do
  let(:job) { Factories.job }
  let(:workflow) { Workflows::Rebase.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "force_push") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "rebase") }

  it "skips pushing when deterministic auto-rebase already proved the branch was unchanged" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "rebased",
      "changed" => false,
      "post_sha" => "abc",
      "base_sha" => "base"
    })
    handler = described_class.new(run)

    expect(handler).not_to receive(:workspace)

    handler.call

    expect(run.job_logs.pluck(:chunk).join("\n")).to include("force_push: skipped")
  end

  it "pushes with an explicit lease from the auto_rebase remote SHA" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "conflict",
      "pre_sha" => "abc123"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)

    handler.call

    expect(git).to have_received(:run).with(
      "push",
      "--force-with-lease=refs/heads/syrus/issue-42:abc123",
      "https://push.example/repo.git",
      "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
  end

  it "leases against the post-rebase SHA after a clean deterministic auto-rebase already pushed" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "rebased",
      "changed" => true,
      "pre_sha" => "before123",
      "post_sha" => "after456"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run)

    handler.call

    expect(git).to have_received(:run).with(
      "push",
      "--force-with-lease=refs/heads/syrus/issue-42:after456",
      "https://push.example/repo.git",
      "HEAD:refs/heads/syrus/issue-42",
      chdir: "/tmp/workspace"
    )
  end

  it "fails visibly when the lease-protected push is rejected" do
    workflow.set_artifact!("auto_rebase_result", {
      "reason" => "conflict",
      "pre_sha" => "abc123"
    })
    handler = described_class.new(run)
    workspace = instance_double(WorkflowWorkspace,
                                setup: nil,
                                branch_name: "syrus/issue-42",
                                path: Pathname.new("/tmp/workspace"))
    git = instance_double(GitRunner)

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(git).to receive(:run).and_raise(
      GitRunner::GitError.new(
        [ "push", "--force-with-lease=refs/heads/syrus/issue-42:abc123" ],
        1,
        "! [rejected] HEAD -> syrus/issue-42 (stale info)"
      )
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /lease rejected/)
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("remote branch moved")
  end
end
