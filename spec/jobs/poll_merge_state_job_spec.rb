require "rails_helper"
require "ostruct"

RSpec.describe PollMergeStateJob, :ci_only do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1") }

  def pr(mergeable_state: "clean", mergeable: true, merged: false, state: "open", head_sha: "abc", base_ref: "main", base_sha: "base")
    repo = OpenStruct.new(full_name: "acme/widgets")
    OpenStruct.new(
      merged: merged,
      state: state,
      mergeable: mergeable,
      mergeable_state: mergeable_state,
      labels: [],
      head: OpenStruct.new(repo: repo, sha: head_sha),
      base: OpenStruct.new(repo: repo, ref: base_ref, sha: base_sha)
    )
  end

  before do
    job.mark_implemented! if job.may_mark_implemented?
    job.save!
    job.workflows.update_all(state: "succeeded")
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr)
    allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([ OpenStruct.new(state: "APPROVED") ])
    allow_any_instance_of(GithubClient).to receive(:pr_issue_comments).and_return([])
    allow_any_instance_of(GithubClient).to receive(:pr_commits).and_return([])
    allow_any_instance_of(GithubClient).to receive(:branch_head_sha).and_return("base")
  end

  it "marks clean approved PRs approved for the landing queue" do
    expect {
      described_class.perform_now(job.id)
    }.to change { job.reload.state }.to("approved")

    expect(job.approved_at).to be_present
  end

  it "short-circuits when polling is paused, even if the child job was already queued" do
    AppSetting.current.update!(polling_paused: true)

    expect_any_instance_of(GithubClient).not_to receive(:pull_request)

    expect {
      described_class.perform_now(job.id)
    }.not_to change { job.reload.pr_mergeable_checked_at }
  ensure
    AppSetting.current.update!(polling_paused: false)
  end

  it "uses the cached GitHub client path for periodic polling" do
    expect_any_instance_of(GithubClient)
      .to receive(:pull_request)
      .with("acme/widgets", 7, bypass_cache: false)
      .and_return(pr)

    described_class.perform_now(job.id)
  end

  it "fetches the PR from effective_pr_repository when it differs from repository" do
    upstream = Factories.repository(user: user, owner: "upstream-org", name: "widgets", auto_merge_enabled: true)
    fork_job = Factories.job(user: user, repository: repository, pr_number: 8, pr_repository: upstream,
                             branch_name: "syrus/issue-42-x")
    fork_job.mark_implemented! if fork_job.may_mark_implemented?
    fork_job.save!
    fork_job.workflows.update_all(state: "succeeded")

    expect_any_instance_of(GithubClient)
      .to receive(:pull_request)
      .with("upstream-org/widgets", 8, bypass_cache: false)
      .and_return(pr)

    described_class.perform_now(fork_job.id)
  end

  it "re-approves after a cancelled transient auto-merge attempt" do
    cancelled = Workflows::AutoMerge.instantiate(job: job)
    cancelled.cancel!
    cancelled.save!
    job.update!(state: "implemented", approved_at: nil)

    expect {
      described_class.perform_now(job.id)
    }.to change { job.reload.state }.from("implemented").to("approved")
  end

  it "queues a clean child instead of merging it before its parent" do
    parent = Factories.job(user: user, repository: repository, issue_number: 41, pr_number: 6)
    job.update!(parent_job: parent)

    described_class.perform_now(job.id)

    expect(job.reload).to be_approved
    entry = LandingQueueProcessor.entries(Job.where(id: job.id)).first
    expect(entry.blocked_reason).to eq({ key: "waiting_to_merge", params: { slug: parent.slug } })
  end

  it "dispatches Rebase when approved but behind" do
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(
      pr(mergeable_state: "behind", mergeable: false, base_ref: "syrus/parent", base_sha: "parent-sha")
    )

    expect {
      described_class.perform_now(job.id)
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    workflow = job.workflows.where(trigger_kind: "rebase").last
    expect(workflow.artifact("rebase_base_branch")).to eq("syrus/parent")
    expect(workflow.artifact("rebase_base_sha")).to eq("parent-sha")
  end

  it "dispatches Rebase when unapproved but dirty" do
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: "dirty", mergeable: false))
    allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([])

    expect {
      described_class.perform_now(job.id)
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
  end

  it "does not instantiate a rebase workflow when stack dependencies are not ready" do
    parent = Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 41,
      state: "implemented",
      branch_name: "syrus/issue-41-1",
      pr_number: 6
    )
    job.dependencies.create!(depends_on_job: parent, source: "manual")
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: "dirty", mergeable: false))
    allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([])

    expect(job.reload).not_to be_dependencies_satisfied_for_execution

    expect {
      described_class.perform_now(job.id)
    }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
  end

  it "does not instantiate a rebase workflow when a dependency was cancelled" do
    parent = Factories.job_record(
      user: user,
      repository: repository,
      issue_number: 41,
      state: "closed",
      closure_reason: "cancelled",
      branch_name: "syrus/issue-41-1",
      pr_number: 6
    )
    job.dependencies.create!(depends_on_job: parent, source: "manual")
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: "dirty", mergeable: false))
    allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([])

    expect(job.reload).to be_dependencies_failed_for_execution

    expect {
      described_class.perform_now(job.id)
    }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
  end

  describe "proactive rebase is limited to the front of the landing queue" do
    before do
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(
        pr(mergeable_state: "behind", mergeable: false)
      )
    end

    def approved_sibling(pr_number, approved_at)
      sibling = Factories.job(user: user, repository: repository, pr_number: pr_number, branch_name: "syrus/sib-#{pr_number}")
      sibling.update_columns(state: "approved", approved_at: approved_at, approved_via: "operator")
      sibling
    end

    it "skips the rebase for an approved Job far back in the queue" do
      job.update_columns(state: "approved", approved_at: 1.minute.ago, approved_via: "operator")
      # Fill the prefetch window with siblings approved earlier, so the
      # target Job sorts behind all of them.
      LandingQueueProcessor::REBASE_PREFETCH_DEPTH.times do |i|
        approved_sibling(100 + i, (10 + i).minutes.ago)
      end

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
    end

    it "still rebases an approved Job at the front of the queue" do
      job.update_columns(state: "approved", approved_at: 30.minutes.ago, approved_via: "operator")
      approved_sibling(200, 1.minute.ago) # approved later → sorts behind the target

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
    end
  end

  it "does not dispatch Rebase when the latest no-op rebase already covered the same head/base" do
    Workflows::Rebase.instantiate(job: job).update!(
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
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: "behind", mergeable: false))

    expect {
      described_class.perform_now(job.id)
    }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
  end

  it "dispatches Rebase when GitHub's PR base sha is stale after a no-op rebase" do
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
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: "behind", mergeable: false, base_sha: "old-base"))
    allow_any_instance_of(GithubClient).to receive(:branch_head_sha).with("acme/widgets", "main").and_return("new-live-base")

    expect {
      described_class.perform_now(job.id)
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
  end

  describe "failed rebase cooldown" do
    before do
      AppSetting.current.update!(rebase_failure_cooldown_minutes: 60)
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(
        pr(mergeable_state: "dirty", mergeable: false, head_sha: "abc", base_sha: "base")
      )
      allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([])
    end

    def failed_agent_rebase!(finished_at:, pre_sha: "abc", base_sha: "base")
      workflow = Workflows::Rebase.instantiate(
        job: job,
        artifacts: {
          "auto_rebase_result" => {
            "succeeded" => false,
            "reason" => "conflict",
            "pre_sha" => pre_sha,
            "base_sha" => base_sha
          }
        }
      )
      workflow.steps.find_by!(kind: "agent_rebase").update!(state: "failed", finished_at: finished_at)
      workflow.update!(state: "failed", finished_at: finished_at)
      workflow
    end

    it "does not redispatch an unchanged recently failed agent rebase" do
      failed_agent_rebase!(finished_at: 10.minutes.ago)

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
    end

    it "redispatches when the PR head changes" do
      failed_agent_rebase!(finished_at: 10.minutes.ago, pre_sha: "old-head")

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
    end

    it "redispatches after the cooldown expires" do
      failed_agent_rebase!(finished_at: 61.minutes.ago)

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
    end
  end

  it "waits on failing checks instead of rebasing" do
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: "blocked", mergeable: false))

    expect {
      described_class.perform_now(job.id)
    }.not_to change(Workflow, :count)
  end

  [ "unknown", "has_hooks" ].each do |mergeable_state|
    it "waits while mergeable_state is #{mergeable_state.inspect}" do
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: mergeable_state, mergeable: nil))

      expect {
        described_class.perform_now(job.id)
      }.not_to change(Workflow, :count)

      expect(job.reload).to be_implemented
    end
  end

  it "skips when any non-terminal workflow exists" do
    Workflow.create!(job: job, trigger_kind: "pr_comment", state: "queued")

    expect {
      described_class.perform_now(job.id)
    }.not_to change(Workflow, :count)
  end

  it "uses external_pr_number when the Job has no Syrus-authored PR" do
    external = Factories.job(user: user, repository: repository, pr_number: nil)
    external.update!(state: "closed", closure_reason: "preempted",
                     external_pr_number: 99, finished_at: Time.current)
    external.workflows.update_all(state: "succeeded")
    expect_any_instance_of(GithubClient)
      .to receive(:pull_request)
      .with("acme/widgets", 99, bypass_cache: false)
      .and_return(pr)

    described_class.perform_now(external.id)
  end

  describe "review approval sync on approve_for_landing" do
    it "creates a JobApproval for a Syrus user whose GitHub review triggered landing approval" do
      reviewer = Factories.user(github_handle: "reviewer")
      submitted = 1.hour.ago
      allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([
        OpenStruct.new(state: "APPROVED", user: OpenStruct.new(login: "reviewer"), submitted_at: submitted.iso8601)
      ])

      expect {
        described_class.perform_now(job.id)
      }.to change { job.job_approvals.count }.by(1)

      approval = job.job_approvals.find_by(user: reviewer)
      expect(approval).to be_present
      expect(approval.approved_at).to be_within(1.second).of(submitted)
    end

    it "does not create a duplicate JobApproval when one already exists for the reviewer" do
      reviewer = Factories.user(github_handle: "reviewer")
      job.job_approvals.create!(user: reviewer, approved_at: 2.hours.ago)
      allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([
        OpenStruct.new(state: "APPROVED", user: OpenStruct.new(login: "reviewer"), submitted_at: 1.hour.ago.iso8601)
      ])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.job_approvals.count }
    end

    it "does not create a JobApproval for an external approver with no Syrus account" do
      allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([
        OpenStruct.new(state: "APPROVED", user: OpenStruct.new(login: "outsider"), submitted_at: 1.hour.ago.iso8601)
      ])

      expect {
        described_class.perform_now(job.id)
      }.not_to change { JobApproval.count }

      expect(job.reload).to be_approved
    end
  end

  describe "stack rebase churn guard" do
    # A stack job must have open children so RebaseWorkflowSelector.stack_rebase? returns true.
    let(:parent_job) { Factories.job(user: user, repository: repository, issue_number: 41, pr_number: 6, branch_name: "syrus/issue-41-1") }
    let(:child_job)  { Factories.job(user: user, repository: repository, issue_number: 43, pr_number: 8, branch_name: "syrus/issue-43-1") }

    before do
      job.update!(parent_job: parent_job)
      child_job.update!(parent_job: job)
      child_job.workflows.update_all(state: "succeeded")
      parent_job.workflows.update_all(state: "succeeded")
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(
        pr(mergeable_state: "dirty", mergeable: false)
      )
      allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([])
    end

    it "skips stack rebase dispatch when the last cancel was due to unready deps and the parent hasn't changed" do
      blocked_at = 10.minutes.ago
      Workflows::StackRebase.instantiate(job: job).update!(
        state: "cancelled",
        artifacts: {
          "start_blocked_reason" => "stack_dependencies_not_ready",
          "start_blocked_at"     => blocked_at.iso8601
        }
      )
      parent_job.update_columns(updated_at: blocked_at - 1.minute)

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "stack_rebase").count }
    end

    it "dispatches stack rebase when the parent job was updated after the last blocked cancel" do
      blocked_at = 10.minutes.ago
      Workflows::StackRebase.instantiate(job: job).update!(
        state: "cancelled",
        artifacts: {
          "start_blocked_reason" => "stack_dependencies_not_ready",
          "start_blocked_at"     => blocked_at.iso8601
        }
      )
      parent_job.update_columns(updated_at: blocked_at + 1.minute)

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "stack_rebase").count }.by(1)
    end

    it "dispatches stack rebase when there is no prior blocked cancel" do
      parent_job.update_columns(updated_at: 30.minutes.ago)

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "stack_rebase").count }.by(1)
    end

    it "skips stack rebase dispatch after an unchanged recent stack_agent_rebase failure" do
      workflow = Workflows::StackRebase.instantiate(
        job: job,
        artifacts: {
          StackRebasePlan::RESULTS_ARTIFACT => [
            {
              "job_id" => job.id,
              "result" => {
                "succeeded" => false,
                "reason" => "conflict",
                "pre_sha" => "abc",
                "base_sha" => "base"
              }
            }
          ]
        }
      )
      workflow.steps.find_by!(kind: "stack_agent_rebase").update!(state: "failed", finished_at: 10.minutes.ago)
      workflow.update!(state: "failed", finished_at: 10.minutes.ago)

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "stack_rebase").count }
    end
  end

  describe "finalizing preempted Jobs whose external PR is terminal" do
    def preempted_job(external_pr_number: 99)
      job = Factories.job(user: user, repository: repository, pr_number: nil)
      job.update!(state: "closed", closure_reason: "preempted",
                  external_pr_number: external_pr_number, finished_at: Time.current)
      job.workflows.update_all(state: "succeeded")
      job
    end

    it "finalizes to external_pr_merged and stops bumping mergeability when the external PR merged" do
      preempted = preempted_job
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(merged: true, state: "closed"))

      described_class.perform_now(preempted.id)

      expect(preempted.reload.closure_reason).to eq("external_pr_merged")
      expect(preempted.pr_mergeable_checked_at).to be_nil # persist_mergeability skipped
    end

    it "finalizes to external_pr_closed when the external PR was closed unmerged" do
      preempted = preempted_job
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(merged: false, state: "closed"))

      described_class.perform_now(preempted.id)

      expect(preempted.reload.closure_reason).to eq("external_pr_closed")
    end

    it "leaves a preempted Job alone while its external PR is still open" do
      preempted = preempted_job
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(merged: false, state: "open"))

      described_class.perform_now(preempted.id)

      expect(preempted.reload.closure_reason).to eq("preempted")
    end
  end

  describe "proactive rebase on commit-distance threshold" do
    let(:fake_clone) { instance_double(RepositoryBareClone) }

    before do
      allow(RepositoryBareClone).to receive(:new).and_return(fake_clone)
      allow(fake_clone).to receive(:sync!)
      allow(fake_clone).to receive(:commits_behind).and_return(21)
      allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(
        pr(mergeable_state: "clean", mergeable: true)
      )
      allow_any_instance_of(GithubClient).to receive(:pr_reviews).and_return([])
    end

    it "dispatches a rebase when commits_behind_base exceeds the threshold and mergeable_state is clean" do
      AppSetting.current.update!(proactive_rebase_commit_threshold: 20)

      expect {
        described_class.perform_now(job.id)
      }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)
    end

    it "does not dispatch a rebase when commits_behind_base equals the threshold" do
      allow(fake_clone).to receive(:commits_behind).and_return(20)
      AppSetting.current.update!(proactive_rebase_commit_threshold: 20)

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
    end

    it "does not dispatch a rebase when commits_behind_base is below the threshold" do
      allow(fake_clone).to receive(:commits_behind).and_return(5)
      AppSetting.current.update!(proactive_rebase_commit_threshold: 20)

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
    end

    it "does not dispatch a rebase when commits_behind_base is nil" do
      allow(fake_clone).to receive(:commits_behind).and_return(nil)
      AppSetting.current.update!(proactive_rebase_commit_threshold: 20)

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
    end

    it "still applies all existing guards inside dispatch_rebase" do
      AppSetting.current.update!(proactive_rebase_commit_threshold: 20)
      job.update_columns(state: "approved", approved_at: 1.minute.ago, approved_via: "operator")
      LandingQueueProcessor::REBASE_PREFETCH_DEPTH.times do |i|
        sibling = Factories.job(user: user, repository: repository, pr_number: 100 + i, branch_name: "syrus/sib-#{100 + i}")
        sibling.update_columns(state: "approved", approved_at: (10 + i).minutes.ago, approved_via: "operator")
      end

      expect {
        described_class.perform_now(job.id)
      }.not_to change { job.workflows.where(trigger_kind: "rebase").count }
    end
  end

  describe "commits_behind_base computation" do
    let(:fake_clone) { instance_double(RepositoryBareClone) }

    before do
      allow(RepositoryBareClone).to receive(:new).and_return(fake_clone)
      allow(fake_clone).to receive(:sync!)
      allow(fake_clone).to receive(:commits_behind).and_return(5)
    end

    it "stores the computed distance on the job" do
      described_class.perform_now(job.id)

      expect(job.reload.commits_behind_base).to eq(5)
    end

    it "passes head_sha and base_sha from the PR to the bare clone" do
      expect(fake_clone).to receive(:commits_behind).with(head_sha: "abc", base_sha: "base")

      described_class.perform_now(job.id)
    end

    it "leaves commits_behind_base nil when the bare clone raises" do
      allow(fake_clone).to receive(:sync!).and_raise(GitRunner::GitError.new(["fetch"], 1, "error"))

      described_class.perform_now(job.id)

      expect(job.reload.commits_behind_base).to be_nil
    end

    it "leaves commits_behind_base nil when commits_behind returns nil" do
      allow(fake_clone).to receive(:commits_behind).and_return(nil)

      described_class.perform_now(job.id)

      expect(job.reload.commits_behind_base).to be_nil
    end

    it "syncs the effective_pr_repository bare clone" do
      expect(RepositoryBareClone).to receive(:new).with(repository).and_return(fake_clone)

      described_class.perform_now(job.id)
    end
  end
end
