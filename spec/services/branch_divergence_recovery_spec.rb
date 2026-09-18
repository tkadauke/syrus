require "rails_helper"

RSpec.describe BranchDivergenceRecovery do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repository, issue_number: 42, pr_number: 7, state: "failed", branch_name: "syrus/issue-42-1") }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "retry", agent_provider: "claude", state: "failed") }

  before do
    workflow.set_artifact!("branch_divergence", {
      "branch" => "syrus/issue-42-1",
      "remote_sha" => "remote-sha",
      "local_sha" => "local-sha"
    })
  end

  it "records discarded output and restores the job to implemented" do
    allow(VisualDiffSubmission).to receive(:enqueue_deferred_for_job)

    result = described_class.discard!(workflow: workflow, user: user)

    expect(result).to be_success
    expect(workflow.reload.artifact("branch_divergence_recovery")).to include(
      "action" => "discarded",
      "user_id" => user.id
    )
    expect(job.reload).to be_implemented
    expect(VisualDiffSubmission).not_to have_received(:enqueue_deferred_for_job)
  end

  it "auto-discards superseded output only when the current PR head matches the recorded remote SHA" do
    job.update!(mergeability_head_sha: "remote-sha")

    result = described_class.discard_superseded!(workflow: workflow)

    expect(result).to be_success
    expect(workflow.reload.artifact("branch_divergence_recovery")).to include(
      "action" => "superseded_by_current_pr_branch"
    )
    expect(workflow.artifact("branch_divergence_recovery")).not_to have_key("user_id")
    expect(job.reload).to be_implemented
  end

  it "does not auto-discard superseded output when the current PR head no longer matches" do
    job.update!(mergeability_head_sha: "newer-remote-sha")

    result = described_class.discard_superseded!(workflow: workflow)

    expect(result).not_to be_success
    expect(result.error).to eq("Current PR head no longer matches the recorded remote SHA.")
    expect(workflow.reload.artifact("branch_divergence_recovery")).to be_nil
  end

  it "lets an operator adopt the current PR head even when it moved past the recorded remote SHA" do
    job.update!(mergeability_head_sha: "newer-remote-sha")

    result = described_class.adopt_current_pr_head!(workflow: workflow, user: user)

    expect(result).to be_success
    expect(workflow.reload.artifact("branch_divergence_recovery")).to include(
      "action" => "adopted_current_pr_head",
      "current_pr_head_sha" => "newer-remote-sha",
      "user_id" => user.id
    )
    expect(job.reload).to be_implemented
  end

  it "force-pushes with a lease against the observed remote SHA" do
    Dir.mktmpdir("syrus-branch-divergence-recovery") do |dir|
      git = instance_double(GitRunner)
      client = instance_double(GithubClient, access_token: "token")

      allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new(dir))
      allow(GitRunner).to receive(:new).and_return(git)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
      allow(git).to receive(:run)

      result = described_class.force_push!(workflow: workflow, user: user)

      expect(result).to be_success
      expect(git).to have_received(:run).with(
        "push",
        "--force-with-lease=refs/heads/syrus/issue-42-1:remote-sha",
        repository.authenticated_push_url("token"),
        "HEAD:refs/heads/syrus/issue-42-1",
        chdir: dir
      )
      expect(workflow.reload.artifact("branch_divergence_recovery")).to include("action" => "force_pushed")
      expect(job.reload).to be_implemented
    end
  end

  it "records a queued force-push without needing the workspace locally" do
    result = described_class.mark_force_push_pending!(workflow: workflow, user: user)

    expect(result).to be_success
    expect(workflow.reload.artifact("branch_divergence_recovery_pending")).to include(
      "action" => "force_push",
      "user_id" => user.id
    )
    expect(workflow.artifact("branch_divergence_recovery_error")).to be_nil
  end

  it "records worker-side force-push failures" do
    result = described_class.record_failure!(workflow: workflow, user: user, message: "workspace vanished")

    expect(result).to be_success
    expect(workflow.reload.artifact("branch_divergence_recovery_pending")).to be_nil
    expect(workflow.artifact("branch_divergence_recovery_error")).to include(
      "message" => "workspace vanished",
      "user_id" => user.id
    )
  end

  describe "when the workspace is on another worker" do
    def checkpoint_for(sha)
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "succeeded")
      run = Run.create!(
        job: job, step: step, trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider, state: "succeeded", head_sha: sha
      )
      RunCheckpoint.create!(
        run: run, workflow: workflow, step: step, job: job, repository: repository, user: job.user,
        step_kind: "implement", commit_sha: sha, remote_ref: RunCheckpoint.remote_ref_for(run),
        status: "published", published_at: Time.current
      )
    end

    before do
      allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/syrus-missing-workspace"))
    end

    # The commit is already on the remote as a checkpoint ref, so republishing
    # the branch needs no clone. Requiring one made this fail purely because of
    # which worker picked up the action.
    it "republishes the branch from the published checkpoint" do
      checkpoint_for("local-sha")
      client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
      allow(client).to receive(:update_branch_ref).and_return(true)

      result = described_class.force_push!(workflow: workflow, user: user)

      expect(result).to be_success
      expect(client).to have_received(:update_branch_ref)
        .with("acme/widgets", "syrus/issue-42-1", "local-sha", expected_sha: "remote-sha")
      expect(workflow.reload.artifact("branch_divergence_recovery")).to include("action" => "force_pushed")
      expect(job.reload).to be_implemented
    end

    it "surfaces a refused lease instead of overwriting a branch that moved again" do
      checkpoint_for("local-sha")
      client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
      allow(client).to receive(:update_branch_ref)
        .and_raise(GithubClient::RefLeaseFailed, "acme/widgets@syrus/issue-42-1 moved to abc123def456")

      result = described_class.force_push!(workflow: workflow, user: user)

      expect(result).not_to be_success
      expect(result.error).to include("Force-push refused")
      expect(workflow.reload.artifact("branch_divergence_recovery")).to be_nil
    end

    # A checkpoint for some other commit is not this workflow's output;
    # publishing it would push a tree the operator was never shown.
    it "refuses a checkpoint that does not hold the diverged commit" do
      checkpoint_for("some-other-sha")

      result = described_class.force_push!(workflow: workflow, user: user)

      expect(result).not_to be_success
      expect(result.error).to eq("Workflow workspace is not available on this worker - retry from the current PR branch instead.")
    end

    it "refuses a checkpoint that was never published to the remote" do
      checkpoint_for("local-sha").update!(status: "pending")

      result = described_class.force_push!(workflow: workflow, user: user)

      expect(result).not_to be_success
      expect(result.error).to eq("Workflow workspace is not available on this worker - retry from the current PR branch instead.")
    end
  end

  it "reports unavailable workspaces without claiming they were cleaned up" do
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/syrus-missing-workspace"))

    result = described_class.force_push!(workflow: workflow, user: user)

    expect(result).not_to be_success
    expect(result.error).to eq("Workflow workspace is not available on this worker - retry from the current PR branch instead.")
  end

  it "leaves a pending retry_workflow attempt untouched when workspace-unavailable recovery fails" do
    step = Step.create!(workflow: workflow, kind: "pr_open", position: 0, state: "failed")
    failed_run = Run.create!(job: job, step: step, trigger_kind: workflow.trigger_kind, agent_provider: "claude", state: "failed")
    attempt = AutoRetryAttempt.create!(
      job: job,
      workflow: workflow,
      run: failed_run,
      agent_provider: "claude",
      failure_classification: "branch_diverged",
      retry_kind: "retry_workflow",
      attempt_number: 1,
      scheduled_at: 5.minutes.from_now
    )
    allow(WorkflowWorkspace).to receive(:path_for).with(workflow).and_return(Pathname.new("/tmp/syrus-missing-workspace"))

    result = described_class.force_push!(workflow: workflow, user: user)
    described_class.record_failure!(workflow: workflow, user: user, message: result.error) unless result.success?

    expect(result).not_to be_success
    expect(workflow.reload.artifact("branch_divergence_recovery")).to be_nil
    expect(attempt.reload.skipped_reason).to be_nil
  end

  it "does not force-push approved jobs" do
    job.update!(state: "approved")

    result = described_class.force_push!(workflow: workflow, user: user)

    expect(result).not_to be_success
    expect(result.error).to eq("Unapprove before replacing the PR branch.")
  end

  describe "idempotency once a divergence is already resolved" do
    before do
      allow(VisualDiffSubmission).to receive(:enqueue_deferred_for_job)
      described_class.discard!(workflow: workflow, user: user)
    end

    it "refuses a second force-push instead of replaying the push" do
      git = instance_double(GitRunner)
      allow(GitRunner).to receive(:new).and_return(git)
      allow(git).to receive(:run)

      result = described_class.force_push!(workflow: workflow, user: user)

      expect(result).not_to be_success
      expect(result.error).to eq("Branch divergence was already resolved (discarded); no further recovery action is needed.")
      expect(git).not_to have_received(:run)
    end

    it "refuses to re-queue a pending force-push" do
      result = described_class.mark_force_push_pending!(workflow: workflow, user: user)

      expect(result).not_to be_success
      expect(result.error).to eq("Branch divergence was already resolved (discarded); no further recovery action is needed.")
      expect(workflow.reload.artifact("branch_divergence_recovery_pending")).to be_nil
    end

    it "refuses a second discard" do
      result = described_class.discard!(workflow: workflow, user: user)

      expect(result).not_to be_success
      expect(result.error).to eq("Branch divergence was already resolved (discarded); no further recovery action is needed.")
    end

    it "refuses to adopt the current PR head after the divergence already resolved" do
      job.update!(mergeability_head_sha: "newer-remote-sha")

      result = described_class.adopt_current_pr_head!(workflow: workflow, user: user)

      expect(result).not_to be_success
      expect(result.error).to eq("Branch divergence was already resolved (discarded); no further recovery action is needed.")
    end
  end

  describe "cancelling stale retry_workflow attempts once recovery succeeds" do
    def pending_retry_workflow_attempt_for(job, workflow, run)
      AutoRetryAttempt.create!(
        job: job,
        workflow: workflow,
        run: run,
        agent_provider: "claude",
        failure_classification: "branch_diverged",
        retry_kind: "retry_workflow",
        attempt_number: 1,
        scheduled_at: 5.minutes.from_now
      )
    end

    def failed_pr_open_run
      step = Step.create!(workflow: workflow, kind: "pr_open", position: 0, state: "failed")
      Run.create!(
        job: job, step: step, trigger_kind: workflow.trigger_kind,
        agent_provider: "claude", state: "failed"
      )
    end

    it "skips a pending retry_workflow auto-retry attempt for the same Job as budget-exempt" do
      allow(VisualDiffSubmission).to receive(:enqueue_deferred_for_job)
      attempt = pending_retry_workflow_attempt_for(job, workflow, failed_pr_open_run)

      result = described_class.discard!(workflow: workflow, user: user)

      expect(result).to be_success
      attempt.reload
      expect(attempt.skipped_reason).to eq("branch divergence recovered via discarded")
      expect(AutoRetryAttempt.skip_reason_category(attempt.skipped_reason)).to eq("branch_divergence_recovered")
    end

    it "does not touch a pending retry_workflow attempt unrelated to this divergence" do
      allow(VisualDiffSubmission).to receive(:enqueue_deferred_for_job)
      unrelated_run = failed_pr_open_run
      unrelated_attempt = AutoRetryAttempt.create!(
        job: job,
        workflow: workflow,
        run: unrelated_run,
        agent_provider: "claude",
        failure_classification: "worker_died",
        retry_kind: "retry_workflow",
        attempt_number: 1,
        scheduled_at: 5.minutes.from_now
      )

      described_class.discard!(workflow: workflow, user: user)

      expect(unrelated_attempt.reload.skipped_reason).to be_nil
    end

    it "cancels a queued retry Workflow spawned for the same Job" do
      allow(VisualDiffSubmission).to receive(:enqueue_deferred_for_job)
      retry_workflow = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: "claude", state: "queued")
      attach_work_unit(retry_workflow, member_jobs: [ job ], kind: "retry", state: "queued")

      result = described_class.discard!(workflow: workflow, user: user)

      expect(result).to be_success
      expect(retry_workflow.reload).to be_cancelled
      expect(retry_workflow.artifact("retry_cancelled_reason")).to eq("branch_divergence_recovered")
    end

    # RetryWorkflowEnqueuer tries RunCheckpointResume first (which covers a
    # failed pr_open step -- exactly this scenario) and only falls back to a
    # plain "retry" Workflow when no safe checkpoint resume is available, so
    # the queued Workflow this needs to catch may carry either WorkUnit kind.
    it "cancels a queued checkpoint_resume Workflow spawned for the same Job" do
      allow(VisualDiffSubmission).to receive(:enqueue_deferred_for_job)
      checkpoint_resume_workflow = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: "claude", state: "queued")
      attach_work_unit(checkpoint_resume_workflow, member_jobs: [ job ], kind: "checkpoint_resume", state: "queued")

      result = described_class.discard!(workflow: workflow, user: user)

      expect(result).to be_success
      expect(checkpoint_resume_workflow.reload).to be_cancelled
      expect(checkpoint_resume_workflow.artifact("retry_cancelled_reason")).to eq("branch_divergence_recovered")
    end
  end
end
