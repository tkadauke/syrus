require "rails_helper"
require "ostruct"

RSpec.describe Steps::AutoMerge do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1") }
  let(:workflow) { Workflows::AutoMerge.instantiate(job: job) }
  let(:step) { workflow.steps.last }
  let(:run) { Run.create!(job: job, step: step, trigger_kind: "auto_merge") }
  let(:client) { instance_double(GithubClient) }

  def pr(state: "open", mergeable_state: "clean", mergeable: true, head_sha: "abc", base_ref: "main", base_sha: "base")
    OpenStruct.new(
      state: state,
      mergeable: mergeable,
      mergeable_state: mergeable_state,
      labels: [],
      head: OpenStruct.new(sha: head_sha),
      base: OpenStruct.new(ref: base_ref, sha: base_sha)
    )
  end

  before do
    job.mark_implemented! if job.may_mark_implemented?
    job.save!

    workflow.start!
    workflow.save!
    step.start!
    step.save!
    run.start!
    run.save!

    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:pull_request).and_return(pr)
    allow(client).to receive(:pr_reviews).and_return([ OpenStruct.new(state: "APPROVED") ])
    allow(client).to receive(:pr_issue_comments).and_return([])
    allow(client).to receive(:pr_commits).and_return([])
    allow(client).to receive(:branch_head_sha).and_return("base")
    allow(client).to receive(:delete_branch)
  end

  def octokit_error(error_class, status:, message:)
    error_class.new(status: status, body: { message: message })
  end

  it "re-verifies gates, merges via GitHub, comments, and closes the Job" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
    allow(client).to receive(:add_issue_comment)

    described_class.new(run).call

    expect(client).to have_received(:merge_pull_request)
      .with("acme/widgets", 7, hash_including(merge_method: "rebase"))
    expect(client).to have_received(:add_issue_comment).with("acme/widgets", 7, include("JOB-#{job.id}"))
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("pr_merged")
  end

  it "cancels the run and workflow when the PR was already closed" do
    allow(ClosedPullRequestResolution).to receive(:reason).and_return("pr_closed")
    allow(client).to receive(:pull_request).and_return(pr(state: "closed"))

    described_class.new(run).call

    expect(run.reload).to be_cancelled
    expect(step.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
  end

  it "closes the Job when the PR was already closed externally so the landing queue isn't blocked" do
    # Job 340 regression: when the gate evaluated to :closed, the
    # old code cancelled the workflow without transitioning the Job
    # out of :landing, leaving the repository permanently occupied
    # in the landing queue.
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    allow(ClosedPullRequestResolution).to receive(:reason).and_return("pr_closed")
    allow(client).to receive(:pull_request).and_return(pr(state: "closed"))

    described_class.new(run).call

    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("pr_closed")
  end

  it "defers landing back to :approved (preserving approval) AND dispatches a Rebase workflow inline when the gate is :needs_rebase" do
    job.approve!(via: "github_review")
    original_approved_at = job.approved_at
    job.start_landing!
    job.save!
    allow(client).to receive(:pull_request).and_return(
      pr(mergeable_state: "behind", base_ref: "syrus/parent", base_sha: "parent-sha")
    )
    allow(StepDispatcher).to receive(:start_workflow)

    expect {
      described_class.new(run).call
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    expect(job.reload).to be_approved
    rebase = job.workflows.where(trigger_kind: "rebase").last
    expect(rebase.artifact("rebase_base_branch")).to eq("syrus/parent")
    expect(rebase.artifact("rebase_base_sha")).to eq("parent-sha")
    # Approval persists across the defer — operator doesn't have to re-approve.
    expect(job.approved_at).to eq(original_approved_at)
    expect(job.approved_via).to eq("github_review")
    expect(StepDispatcher).to have_received(:start_workflow).with(an_instance_of(Workflow))
  end

  it "does not dispatch a second Rebase workflow when one is already active" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    existing = Workflows::Rebase.instantiate(job: job)
    existing.update!(state: "running")
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "behind"))
    allow(StepDispatcher).to receive(:start_workflow)

    expect {
      described_class.new(run).call
    }.not_to change { job.workflows.where(trigger_kind: "rebase").count }

    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "does not dispatch another Rebase workflow when the latest no-op rebase already covered this head/base" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    rebase = Workflows::Rebase.instantiate(job: job)
    rebase.update!(
      state: "succeeded",
      artifacts: {
        "auto_rebase_result" => {
          "reason" => "rebased",
          "changed" => false,
          "post_sha" => "abc",
          "base_sha" => "base"
        }
      }
    )
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "behind", mergeable: false))
    allow(StepDispatcher).to receive(:start_workflow)

    expect {
      described_class.new(run).call
    }.not_to change { job.workflows.where(trigger_kind: "rebase").count }

    expect(job.reload).to be_approved
    expect(job.pr_mergeable).to be false
    expect(run.reload).to be_cancelled
    expect(StepDispatcher).not_to have_received(:start_workflow)
  end

  it "dispatches a fresh Rebase workflow when GitHub's PR base sha is stale after a no-op rebase" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    Workflows::Rebase.instantiate(job: job).update!(
      state: "succeeded",
      artifacts: {
        "auto_rebase_result" => {
          "reason" => "rebased",
          "changed" => false,
          "post_sha" => "abc",
          "base_sha" => "old-base"
        }
      }
    )
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "dirty", mergeable: false, base_sha: "old-base"))
    allow(client).to receive(:branch_head_sha).with("acme/widgets", "main").and_return("new-live-base")
    allow(StepDispatcher).to receive(:start_workflow)

    expect {
      described_class.new(run).call
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    expect(StepDispatcher).to have_received(:start_workflow).with(an_instance_of(Workflow))
  end

  it "fails landing instead of dispatching a rebase once REBASE_ATTEMPT_CAP consecutive rebases have failed" do
    job.approve!(via: "github_review")
    PollRebaseJob::REBASE_ATTEMPT_CAP.times do
      Workflows::Rebase.instantiate(job: job).update!(state: "failed")
    end
    job.start_landing!
    job.save!
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "dirty"))

    expect {
      described_class.new(run).call
    }.to raise_error(Steps::Base::StepFailed, /rebase cap reached/)
  end

  it "defers landing when the gate is :transient so the landing queue can advance" do
    job.approve!(via: "github_review")
    original_approved_at = job.approved_at
    job.start_landing!
    job.save!
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "unknown"))

    described_class.new(run).call

    expect(job.reload).to be_approved
    expect(job.approved_at).to eq(original_approved_at)
  end

  it "waits out a transient 'unknown' (GitHub recomputing after our push) and merges once it settles to clean" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    # First check is "unknown" (GitHub still recomputing after the
    # push step); a beat later it resolves to "clean".
    allow(client).to receive(:pull_request).and_return(
      pr(mergeable_state: "unknown"),
      pr(mergeable_state: "clean")
    )
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
    allow(client).to receive(:add_issue_comment)

    described_class.new(run).call

    expect(client).to have_received(:merge_pull_request)
      .with("acme/widgets", 7, hash_including(merge_method: "rebase"))
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("pr_merged")
  end

  it "gives up and defers only after the settle budget is exhausted" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "unknown"))
    allow(client).to receive(:merge_pull_request)

    described_class.new(run).call

    # Initial evaluation + MERGEABILITY_SETTLE_ATTEMPTS retries.
    expect(client).to have_received(:pull_request)
      .at_least(described_class::MERGEABILITY_SETTLE_ATTEMPTS + 1).times
    expect(client).not_to have_received(:merge_pull_request)
    expect(job.reload).to be_approved
  end

  it "queues the merge attempt while a stack parent is still open" do
    parent = Factories.job(user: user, repository: repository, issue_number: 41, pr_number: 6)
    job.update!(parent_job: parent)
    allow(client).to receive(:merge_pull_request)

    described_class.new(run).call

    expect(client).not_to have_received(:merge_pull_request)
    expect(workflow.reload.artifact("pending_auto_merge")).to eq("waiting_for_parent")
    expect(run.reload).to be_cancelled
    expect(run.job_logs.find { |log| log.chunk.include?("waiting for parent #6 to merge") }.kind).to eq("system")
  end

  {
    "unknown" => "deferred - mergeable_state=unknown",
    "has_hooks" => "deferred - mergeable_state=has_hooks",
    "behind" => "deferred - mergeable_state=behind",
    "dirty" => "deferred - mergeable_state=dirty"
  }.each do |mergeable_state, log_message|
    it "cancels cleanly when mergeable_state is #{mergeable_state.inspect}" do
      allow(client).to receive(:pull_request).and_return(pr(mergeable_state: mergeable_state))
      allow(client).to receive(:merge_pull_request)
      allow(StepDispatcher).to receive(:start_workflow)

      expect { described_class.new(run).call }.not_to raise_error

      expect(client).not_to have_received(:merge_pull_request)
      expect(run.reload).to be_cancelled
      expect(step.reload).to be_cancelled
      expect(workflow.reload).to be_cancelled
      expect(job.reload.failure_count).to eq(0)
      expect(run.job_logs.pluck(:chunk)).to include(include(log_message))
    end
  end

  {
    "blocked" => "PR mergeable_state is \"blocked\""
  }.each do |mergeable_state, error_message|
    it "raises StepFailed when mergeable_state is #{mergeable_state.inspect}" do
      allow(client).to receive(:pull_request).and_return(pr(mergeable_state: mergeable_state))

      expect {
        described_class.new(run).call
      }.to raise_error(Steps::Base::StepFailed, /#{Regexp.escape(error_message)}/)

      expect(run.reload).to be_running
      expect(step.reload).to be_running
      expect(workflow.reload).to be_running
    end
  end

  # Regression: production hit "auto_merge: PR mergeable_state is
  # \"unstable\"" → fail_landing wiped the approval. `unstable`
  # means a non-required CI check is failing but the merge call
  # itself would succeed. AutoMergeGate now treats it as :ready;
  # if GitHub actually refuses the merge, the existing
  # TRANSIENT_MERGE_ERRORS path catches it and defers (approval
  # preserved).
  it "attempts the merge when mergeable_state is \"unstable\"" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    allow(client).to receive(:pull_request).and_return(pr(mergeable_state: "unstable"))
    allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
    allow(client).to receive(:add_issue_comment)

    described_class.new(run).call

    expect(client).to have_received(:merge_pull_request)
    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("pr_merged")
  end

  [
    [ Octokit::MethodNotAllowed, 405, "Base branch was modified. Review and try the merge." ],
    [ Octokit::Conflict, 409, "Pull request head is changing." ],
    [ Octokit::ServiceUnavailable, 503, "GitHub is temporarily unavailable." ],
    [ Octokit::InternalServerError, 500, "GitHub had an internal error." ]
  ].each do |error_class, status, message|
    it "defers cleanly when merge_pull_request raises #{error_class}" do
      job.approve!(via: "github_review")
      job.start_landing!
      job.save!
      allow(client).to receive(:merge_pull_request)
        .and_raise(octokit_error(error_class, status: status, message: message))

      expect {
        described_class.new(run).call
      }.not_to change { job.reload.failure_count }
      expect(workflow.reload.failure_count).to eq(0)
      expect(job.reload).to be_approved
      expect(run.reload).to be_cancelled
      expect(step.reload).to be_cancelled
      expect(workflow.reload).to be_cancelled

      log = run.job_logs.find { |entry| entry.chunk.include?("auto_merge: deferred") }
      expect(log.kind).to eq("system")
      expect(log.chunk).to include("auto_merge: deferred")
      expect(log.chunk).to include(message)
    end
  end

  it "defers and dispatches a rebase workflow when GitHub rejects the rebase merge" do
    job.approve!(via: "github_review")
    original_approved_at = job.approved_at
    job.start_landing!
    job.save!
    allow(StepDispatcher).to receive(:start_workflow)
    allow(client).to receive(:merge_pull_request)
      .and_raise(octokit_error(Octokit::MethodNotAllowed, status: 405, message: "This branch can't be rebased"))

    expect {
      described_class.new(run).call
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    expect(job.reload).to be_approved
    expect(job.approved_at).to eq(original_approved_at)
    expect(run.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
    expect(StepDispatcher).to have_received(:start_workflow).with(an_instance_of(Workflow))
    expect(run.job_logs.pluck(:chunk)).to include(include("GitHub rejected rebase merge"))
  end

  it "raises StepFailed for persistent Octokit merge errors" do
    job.approve!(via: "github_review")
    job.start_landing!
    job.save!
    allow(client).to receive(:merge_pull_request)
      .and_raise(octokit_error(Octokit::Forbidden, status: 403, message: "Branch protection blocked the merge."))

    expect {
      described_class.new(run).call
    }.to raise_error(Steps::Base::StepFailed, /GitHub merge failed/)

    expect(run.reload).to be_running
    expect(workflow.reload).to be_running
  end

  describe "branch deletion after merge" do
    before do
      job.approve!(via: "github_review")
      job.start_landing!
      job.save!
      allow(client).to receive(:merge_pull_request).and_return(OpenStruct.new(merged: true))
      allow(client).to receive(:add_issue_comment)
      allow(client).to receive(:delete_branch)
    end

    it "deletes the branch and stamps branch_deleted_at after a successful merge" do
      described_class.new(run).call

      expect(client).to have_received(:delete_branch).with("acme/widgets", "syrus/issue-42-1")
      expect(job.reload.branch_deleted_at).to be_present
    end

    it "skips delete_branch when branch_name is absent" do
      job.update!(branch_name: nil)

      described_class.new(run).call

      expect(client).not_to have_received(:delete_branch)
      expect(job.reload.branch_deleted_at).to be_nil
    end
  end
end
