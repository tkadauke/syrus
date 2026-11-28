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
      { "branch_name" => "syrus/direct-5004", "pre_sha" => "abc123", "post_sha" => "def456" }
    ])
    workflow.set_artifact!(StackRebasePlan::STACK_ARTIFACT, [])

    allow(handler).to receive(:workspace).and_return(workspace)
    allow(handler).to receive(:streaming_git).and_return(git)
    client = instance_double(GithubClient, access_token: "token", branch_head_sha: nil)
    allow(GithubClient).to receive(:for).and_return(client)
    allow(job.repository).to receive(:authenticated_push_url).with("token").and_return("https://push.example/repo.git")
    allow(LandingQueueProcessor).to receive(:refresh_snapshot!).and_return([])
  end

  it "pushes the recorded rebased commit when the local branch no longer exists" do
    expect(git).to receive(:run).with(
      "push",
      "--force-with-lease=refs/heads/syrus/direct-5004:abc123",
      "https://push.example/repo.git",
      "def456:refs/heads/syrus/direct-5004",
      chdir: "/tmp/workspace"
    )

    handler.call
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

    expect { handler.call }.to raise_error(Steps::Base::StepFailed, /provider failed/)
    expect(run.job_logs.pluck(:chunk).join("\n")).not_to include("lease rejected")
    expect(workflow.reload.artifact("stack_publication_failure")).to include("category" => "provider_failure")
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
    expect(workflow.reload.artifact("stack_publication_failure")).to include("category" => "lease_rejected")
  end

  # Regression: two stack rebases of the same Epic rewrote this branch; the
  # other one published first. Its head holds exactly this rewrite, so the
  # lease rejection is not "newer remote work" and must not fail the stack.
  it "adopts a moved remote that already holds this rewrite" do
    workflow.set_artifact!(StackRebasePlan::AGENT_PUSHES_ARTIFACT, [
      { "job_id" => job.id, "branch_name" => "syrus/direct-5004", "pre_sha" => "abc123", "post_sha" => "def456" }
    ])
    rejection = GitRunner::GitError.new([ "push" ], 1, "! [rejected]        HEAD -> syrus/direct-5004 (stale info)")
    allow(git).to receive(:run).with("push", any_args).and_raise(rejection)
    allow(git).to receive(:run).with("fetch", any_args).and_return("")
    allow(git).to receive(:run).with("rev-parse", "refs/remotes/origin/syrus/direct-5004", chdir: "/tmp/workspace").and_return("fff999\n")
    allow(BranchTruth).to receive(:classify).and_return(
      BranchTruth::Result.new(relation: :equivalent, outcome: :adopt_remote, local_sha: "def456", remote_sha: "fff999",
                              base_sha: nil, local_fresh: nil, remote_fresh: nil, evidence: {})
    )
    verifier = instance_double(StackPublicationVerifier)
    allow(StackPublicationVerifier).to receive(:new).and_return(verifier)
    allow(verifier).to receive(:verify!)

    handler.call

    expect(BranchTruth).to have_received(:classify).with(hash_including(local: "def456", remote: "fff999", rewritten_from: [ "abc123" ]))
    expect(verifier).to have_received(:verify!).with(hash_including(expected_heads: { job.id => "fff999" }))
    expect(workflow.reload.artifact(StackRebasePlan::AGENT_PUSHES_ARTIFACT).first).to include(
      "post_sha" => "fff999", "rebased_sha" => "def456"
    )
    expect(workflow.artifact("stack_publication_failure")).to be_nil
  end

  context "with a deterministic no-op stack rebase" do
    let(:parent) do
      Factories.job_record(
        user: job.user, repository: job.repository, issue_number: 80, pr_number: 80,
        branch_name: "syrus/parent", state: "approved"
      )
    end
    let(:child) do
      Factories.job_record(
        user: job.user, repository: job.repository, issue_number: 81, pr_number: 81,
        branch_name: "syrus/child", state: "approved", parent_job: nil
      )
    end
    let(:client) { instance_double(GithubClient) }
    let(:head_sha) { "c" * 40 }
    let(:base_sha) { "b" * 40 }

    before do
      workflow.set_artifact!(StackRebasePlan::AGENT_PUSHES_ARTIFACT, [])
      workflow.set_artifact!(StackRebasePlan::STACK_ARTIFACT, [
        {
          "job_id" => child.id, "pr_number" => child.pr_number, "branch_name" => child.branch_name,
          "base_branch" => job.repository.default_branch, "parent_job_id" => nil
        }
      ])
      workflow.set_artifact!(StackRebasePlan::RESULTS_ARTIFACT, [
        {
          "job_id" => child.id,
          "result" => { "succeeded" => true, "reason" => "rebased", "changed" => false, "pre_sha" => head_sha, "post_sha" => head_sha }
        }
      ])
      allow(GithubClient).to receive(:for).and_return(client)
      allow(client).to receive(:update_pull_request_base)
      allow(PrStackFooter).to receive(:refresh!)
    end

    it "fails and retains recovery evidence when the requested detach cannot retarget the PR" do
      dependency = JobDependency.create!(job: child, depends_on_job: parent, source: "manual", created_by_user: job.user)
      child.update_columns(parent_job_id: parent.id)
      child.update_columns(mergeability_base_ref: parent.branch_name)
      dependency.destroy!
      child.update_columns(parent_job_id: nil)
      allow(client).to receive(:update_pull_request_base).and_raise(Octokit::Unauthorized.new)
      allow(client).to receive(:branch_head_sha).and_return("r" * 40)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /provider auth failure/)

      expect(workflow.reload.artifact("stack_publication_failure")).to include(
        "category" => "provider_auth_failure",
        "expected_base" => "main",
        "remote_sha" => "r" * 40,
        "local_sha" => head_sha
      )
      expect(workflow.artifact("branch_divergence")).to include("remote_sha" => "r" * 40, "local_sha" => head_sha)
      expect(workflow.artifact("stack_publication")).to be_nil
    end

    it "fails closed when removed dependency topology no longer matches the detach plan" do
      dependency = JobDependency.create!(job: child, depends_on_job: parent, source: "manual", created_by_user: job.user)
      child.update_columns(parent_job_id: parent.id, mergeability_base_ref: parent.branch_name)
      dependency.destroy!

      allow(client).to receive(:branch_head_sha).and_return(head_sha)

      expect { handler.call }.to raise_error(Steps::Base::StepFailed, /derived stack topology/)

      expect(client).not_to have_received(:update_pull_request_base)
      expect(workflow.reload.artifact("stack_publication_failure")).to include(
        "category" => "postcondition_mismatch",
        "expected_parent_job_id" => nil,
        "resolved_parent_job_id" => parent.id,
        "remote_sha" => head_sha,
        "local_sha" => head_sha
      )
      expect(workflow.artifact("stack_publication")).to be_nil
    end

    it "retargets to the newly resolved parent instead of the stale pre-resolution parent" do
      old_parent = Factories.job_record(
        user: job.user, repository: job.repository, issue_number: 82, pr_number: 82,
        branch_name: "syrus/old-parent", state: "approved"
      )
      parent.runs.create!(trigger_kind: "initial", agent_provider: parent.agent_provider, head_sha: "p" * 40)
      JobDependency.create!(job: child, depends_on_job: parent, source: "manual", created_by_user: job.user)
      child.update_columns(parent_job_id: old_parent.id, mergeability_base_ref: old_parent.branch_name)
      workflow.set_artifact!(StackRebasePlan::STACK_ARTIFACT, [
        {
          "job_id" => child.id, "pr_number" => child.pr_number, "branch_name" => child.branch_name,
          "base_branch" => parent.branch_name, "parent_job_id" => parent.id
        }
      ])
      pr = OpenStruct.new(
        head: OpenStruct.new(sha: head_sha),
        base: OpenStruct.new(ref: parent.branch_name, sha: base_sha),
        mergeable: true,
        mergeable_state: "clean"
      )
      allow(client).to receive(:branch_head_sha).and_return(head_sha)
      allow(client).to receive(:pull_request).and_return(pr)
      allow(CommitsBehindCalculator).to receive(:call).and_return(0)

      handler.call

      expect(child.reload.parent_job).to eq(parent)
      expect(client).to have_received(:update_pull_request_base)
        .with(job.repository.slug, child.pr_number, base: parent.branch_name)
      expect(workflow.reload.artifact("stack_publication")).to include("status" => "verified")
    end

    it "rereads and records the verified live publication and refreshed topology" do
      child.update_columns(landing_queue_blocked_reason: "stack_dependencies_not_ready", landing_queue_cached_at: 1.minute.ago)
      pr = OpenStruct.new(
        head: OpenStruct.new(sha: head_sha),
        base: OpenStruct.new(ref: "main", sha: base_sha),
        mergeable: true,
        mergeable_state: "clean"
      )
      allow(client).to receive(:branch_head_sha).with(job.repository.slug, child.branch_name).and_return(head_sha)
      allow(client).to receive(:pull_request).with(job.repository.slug, child.pr_number, bypass_cache: true).and_return(pr)
      allow(CommitsBehindCalculator).to receive(:call).and_return(0)
      allow(LandingQueueProcessor).to receive(:refresh_snapshot!) do
        child.update_columns(landing_queue_blocked_reason: nil, landing_queue_cached_at: Time.current)
        []
      end

      handler.call

      expect(client).to have_received(:update_pull_request_base).with(job.repository.slug, child.pr_number, base: "main")
      expect(child.reload).to have_attributes(
        parent_job_id: nil,
        mergeability_head_sha: head_sha,
        mergeability_base_ref: "main",
        commits_behind_base: 0,
        commits_behind_base_sha: base_sha,
        landing_queue_blocked_reason: nil
      )
      expect(workflow.reload.artifact("stack_publication")).to include(
        "status" => "verified",
        "branch_publication" => "already_correct",
        "members" => [ a_hash_including("remote_head_sha" => head_sha, "live_base" => "main", "live_parent_job_id" => nil) ]
      )
      expect(LandingQueueProcessor).to have_received(:refresh_snapshot!)
    end

    # stack_auto_rebase found this member's work already on the base: it
    # closed the PR and requested the Job's closure, which applies only when
    # the workflow finishes. Its "post_sha" is the unpublished local rebase
    # (the base tip), so it must not be treated as an intended publication.
    it "does not verify or retarget a member whose work stack_auto_rebase found already landed" do
      workflow.set_artifact!(StackRebasePlan::RESULTS_ARTIFACT, [
        {
          "job_id" => child.id,
          "result" => { "succeeded" => true, "reason" => AutoRebase::ALREADY_LANDED_REASON, "changed" => false,
                        "pre_sha" => head_sha, "post_sha" => base_sha }
        }
      ])
      workflow.request_job_closure!(child, "pr_merged")
      allow(client).to receive(:branch_head_sha).and_return(head_sha)
      allow(client).to receive(:pull_request).and_return(OpenStruct.new(
        state: "closed", head: OpenStruct.new(sha: head_sha), base: OpenStruct.new(ref: "main", sha: base_sha)
      ))
      allow(CommitsBehindCalculator).to receive(:call).and_return(0)

      handler.call

      expect(client).not_to have_received(:update_pull_request_base)
      expect(workflow.reload.artifact("stack_publication")).to include("status" => "verified", "members" => [])
    end
  end
end
