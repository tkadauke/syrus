require "rails_helper"
require "ostruct"

RSpec.describe EmergencyLand::Lander do
  # The first User created in the process is auto-promoted to admin
  # (User#promote_first_user_to_admin) -- consume that slot with a decoy
  # admin first so the other lets are guaranteed non-admin regardless of
  # reference order.
  let!(:decoy_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner, owner: "acme", name: "widgets", default_branch: "main") }
  let(:chat_session) { ChatSession.create!(user: owner, repository: repository, mode: "coding", coding_checkout_branch: "syrus/emergency-1") }
  let(:job) do
    Factories.job(
      user: owner,
      repository: repository,
      state: "coding",
      linked_chat_id: chat_session.id,
      branch_name: "syrus/emergency-1",
      issue_title: "Fix the incident"
    )
  end
  let(:client) { instance_double(GithubClient) }

  def stub_ahead_commits(commits: [ { sha: "abc123" } ])
    stub_repository_history(repository, base: "main", head: "syrus/emergency-1", commits: commits, merge_base_sha: "base")
  end

  def stub_open_pr(number: 9)
    allow(client).to receive(:open_pull_request_for_head).and_return(nil)
    allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: number))
  end

  def stub_mergeable_pr(number: 9, mergeable: true, head_sha: "headsha123", head_ref: job.branch_name,
    head_repository: repository.slug, base_ref: job.effective_base_branch)
    allow(client).to receive(:pull_request)
      .with("acme/widgets", number, bypass_cache: true)
      .and_return(OpenStruct.new(
        mergeable: mergeable,
        head: OpenStruct.new(sha: head_sha, ref: head_ref, repo: OpenStruct.new(full_name: head_repository)),
        base: OpenStruct.new(ref: base_ref)
      ))
  end

  def stub_merge(number: 9, merged: true, sha: "mergedsha123", expected_sha: "headsha123")
    allow(client).to receive(:merge_pull_request)
      .with("acme/widgets", number, hash_including(merge_method: "rebase", sha: expected_sha))
      .and_return(OpenStruct.new(merged: merged, sha: sha))
  end

  before do
    allow(Feature).to receive(:emergency_land_enabled?).and_return(true)
  end

  describe "success" do
    it "opens the PR, merges it, and records a distinguishable audit trail" do
      stub_ahead_commits
      stub_open_pr(number: 9)
      stub_mergeable_pr(number: 9)
      stub_merge(number: 9, sha: "mergedsha123")
      expect(client).not_to receive(:compare_commits)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_success
      expect(result.pr_number).to eq(9)
      expect(client).to have_received(:create_pull_request)
        .with("acme/widgets", hash_including(base: "main", head: "acme:syrus/emergency-1"))
      expect(client).to have_received(:merge_pull_request)
        .with("acme/widgets", 9, hash_including(merge_method: "rebase", sha: "headsha123"))

      job.reload
      expect(job).to be_closed
      expect(job.pr_number).to eq(9)
      expect(job.landed_sha).to eq("mergedsha123")
      expect(job.closure_reason).to eq("emergency_landed")
      expect(job.emergency_landed_at).to be_present
      expect(job.emergency_landed_by_user_id).to eq(owner.id)
      expect(job.emergency_landed_by_membership_tier).to eq("admin")
      expect(job.emergency_land_source_sha).to eq("headsha123")
      expect(job.emergency_land_skipped_controls).to eq(%w[graders adversarial_review visual_review admission_control normal_worker_queue])
    end

    it "reuses an already-open PR instead of opening a duplicate" do
      job.update!(pr_number: 4)
      stub_ahead_commits
      stub_mergeable_pr(number: 4)
      stub_merge(number: 4)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_success
      expect(job.reload.pr_number).to eq(4)
    end

    it "refuses a stale PR number whose head does not match the Job branch" do
      job.update!(pr_number: 4)
      stub_ahead_commits
      stub_mergeable_pr(number: 4, head_ref: "unrelated-branch")
      expect(client).not_to receive(:merge_pull_request)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to include("expected main from acme/widgets:syrus/emergency-1")
    end

    it "refuses a PR whose head repository does not match the Job repository" do
      job.update!(pr_number: 4)
      stub_ahead_commits
      stub_mergeable_pr(number: 4, head_repository: "acme/unrelated")

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to include("acme/unrelated:syrus/emergency-1")
    end

    it "refuses a PR whose base does not match the Job's effective base" do
      job.update!(pr_number: 4)
      stub_ahead_commits
      stub_mergeable_pr(number: 4, base_ref: "release")

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to include("targets release")
    end

    it "retires queued zero-run ownership only after safety validation passes" do
      workflow = instance_double(Workflow, queued?: true, runs: instance_double(ActiveRecord::Associations::CollectionProxy, exists?: false))
      unit = instance_double(WorkUnit, workflow: workflow, running?: false, active?: true)
      allow(WorkUnits::Ownership).to receive(:active_units_for_job).with(job).and_return([ unit ], [ unit ], [ unit ], [])
      allow(WorkUnits::WorkflowCancellation).to receive(:cancel!)
      allow(unit).to receive(:preempt!)
      stub_ahead_commits
      stub_open_pr(number: 9)
      stub_mergeable_pr(number: 9)
      stub_merge(number: 9)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_success
      expect(WorkUnits::WorkflowCancellation).to have_received(:cancel!).with(workflow, hash_including(reason: "emergency_land_superseded"))
      expect(unit).to have_received(:preempt!).with(reason: "emergency_land_superseded")
    end

    it "records global_admin as the confirmer tier for a global admin with no repository membership" do
      global_admin = Factories.user(admin: true)
      stub_ahead_commits
      stub_open_pr(number: 9)
      stub_mergeable_pr(number: 9)
      stub_merge(number: 9)

      result = described_class.land(job: job, user: global_admin, client: client)

      expect(result).to be_success
      expect(job.reload.emergency_landed_by_user_id).to eq(global_admin.id)
      expect(job.reload.emergency_landed_by_membership_tier).to eq("global_admin")
    end
  end

  describe "refusal guard clauses" do
    it "refuses when the feature flag is off" do
      allow(Feature).to receive(:emergency_land_enabled?).and_return(false)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/not enabled/i)
    end

    it "refuses a user who fails the repository admin permission check" do
      outsider = Factories.user

      result = described_class.land(job: job, user: outsider, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/admin permission/i)
    end

    it "refuses a write-tier repository member" do
      writer = Factories.user
      RepositoryMembership.create!(repository: repository, user: writer, role: "write")

      result = described_class.land(job: job, user: writer, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/admin permission/i)
    end

    it "accepts implemented as an eligible branch-backed state and continues validation" do
      job.update!(state: "implemented")

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/no pushed commits/i)
    end

    it "does not require Coding Mode takeover for an existing branch-backed Job" do
      chat_session.update!(mode: "planning")

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/no pushed commits/i)
    end

    it "refuses when the workspace has no pushed commits ahead of the default branch" do
      stub_ahead_commits(commits: [])

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/no pushed commits/i)
    end

    it "refuses when the coding branch has not been pushed yet" do
      stub_repository_content(repository, ref: "main", files: {})
      expect(client).not_to receive(:compare_commits)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/no pushed commits/i)
    end

    it "fails instead of treating repository content outages as no commits" do
      stub_repository_content_failure(repository, RepositoryContent::Unavailable.new("mirror and host unavailable"))
      expect(client).not_to receive(:compare_commits)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_failure
      expect(result.message).to match(/Repository content error/i)
    end

    it "refuses when GitHub reports the PR as not mergeable" do
      stub_ahead_commits
      stub_open_pr(number: 9)
      stub_mergeable_pr(number: 9, mergeable: false)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/not mergeable/i)
      expect(job.reload).to be_coding
    end

    it "does not retire queued zero-run ownership when a non-mutating safety check refuses landing" do
      workflow = instance_double(Workflow, queued?: true, runs: instance_double(ActiveRecord::Associations::CollectionProxy, exists?: false))
      unit = instance_double(WorkUnit, workflow: workflow, running?: false, active?: true)
      allow(WorkUnits::Ownership).to receive(:active_units_for_job).with(job).and_return([ unit ])
      allow(WorkUnits::WorkflowCancellation).to receive(:cancel!)
      allow(unit).to receive(:preempt!)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result.message).to match(/no pushed commits/i)
      expect(WorkUnits::WorkflowCancellation).not_to have_received(:cancel!)
      expect(unit).not_to have_received(:preempt!)
    end
  end

  describe "unexpected GitHub failures" do
    it "returns a failure result instead of raising when GitHub reports the merge failed" do
      stub_ahead_commits
      stub_open_pr(number: 9)
      stub_mergeable_pr(number: 9)
      stub_merge(number: 9, merged: false)

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_failure
      expect(job.reload).to be_coding
    end

    it "returns a failure result when GitHub raises an Octokit error" do
      stub_ahead_commits
      allow(client).to receive(:open_pull_request_for_head).and_raise(Octokit::ServiceUnavailable.new(status: 503, body: { message: "down" }))

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_failure
      expect(job.reload).to be_coding
    end
  end
end
