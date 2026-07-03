require "rails_helper"
require "ostruct"

RSpec.describe PollMergeStateJob do
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
    expect(entry.blocked_reason).to include("waiting for #41 to merge")
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
end
