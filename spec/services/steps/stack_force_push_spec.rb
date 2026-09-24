require "rails_helper"

RSpec.describe Steps::StackForcePush do
  let(:job) { Factories.job }
  let(:workflow) { Workflows::StackRebase.instantiate(job: job) }
  let(:step) { workflow.steps.find_by!(kind: "stack_force_push") }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "stack_rebase") }
  let(:handler) { described_class.new(run) }
  let(:workspace) { instance_double(WorkflowWorkspace, setup: nil, path: Pathname.new("/tmp/workspace")) }
  let(:git) { instance_double(GitRunner) }

  before do
    workflow.set_artifact!(StackRebasePlan::AGENT_PUSHES_ARTIFACT, [
      { "branch_name" => "syrus/direct-5004", "pre_sha" => "abc123" }
    ])
    workflow.set_artifact!(StackRebasePlan::STACK_ARTIFACT, [])

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    allow(GithubClient).to receive(:for).and_return(instance_double(GithubClient, access_token: "token"))
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
  end

  # The old shared PUSH_REJECTED_PATTERN's
  # bare /rejected/i matched the "rejected" token inside a server-side
  # "[remote rejected] ... (Internal Server Error)" refusal too, so a
  # transient GitHub 500 was misdiagnosed as a force-with-lease conflict and
  # raised as "lease rejected ... remote branch moved after Syrus fetched
  # it" -- discarding completed stack_agent_rebase conflict-resolution work
  # and terminally failing the stack_rebase workflow instead of letting it
  # retry a transient outage.
  it "does not misclassify a GitHub 5xx '[remote rejected]' push failure as a lease conflict" do
    allow(git).to receive(:run).and_raise(
      GitRunner::GitError.new(
        [ "push", "--force-with-lease=refs/heads/syrus/direct-5004:abc123" ],
        1,
        "remote: Internal Server Error\n" \
        "To github.com:owner/repo.git\n" \
        " ! [remote rejected] syrus/direct-5004 -> syrus/direct-5004 (Internal Server Error)\n" \
        "error: failed to push some refs to 'github.com:owner/repo.git'"
      )
    )

    expect { handler.call }.to raise_error(GitRunner::GitError)
    expect(run.job_logs.pluck(:chunk).join("\n")).not_to include("lease rejected")
  end

  it "still classifies a genuine non-fast-forward lease rejection and fails visibly" do
    allow(git).to receive(:run).and_raise(
      GitRunner::GitError.new(
        [ "push", "--force-with-lease=refs/heads/syrus/direct-5004:abc123" ],
        1,
        "! [rejected]        HEAD -> syrus/direct-5004 (stale info)"
      )
    )

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /lease rejected/)
    expect(run.job_logs.pluck(:chunk).join("\n")).to include("remote branch moved")
  end
end
