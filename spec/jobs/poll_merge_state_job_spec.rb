require "rails_helper"
require "ostruct"

RSpec.describe PollMergeStateJob do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7, branch_name: "syrus/issue-42-1") }

  def pr(mergeable_state: "clean", mergeable: true, merged: false, state: "open")
    repo = OpenStruct.new(full_name: "acme/widgets")
    OpenStruct.new(
      merged: merged,
      state: state,
      mergeable: mergeable,
      mergeable_state: mergeable_state,
      labels: [],
      head: OpenStruct.new(repo: repo, sha: "abc"),
      base: OpenStruct.new(repo: repo)
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
  end

  it "marks clean approved PRs approved for the landing queue" do
    expect {
      described_class.perform_now(job.id)
    }.to change { job.reload.state }.to("approved")

    expect(job.approved_at).to be_present
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
    allow_any_instance_of(GithubClient).to receive(:pull_request).and_return(pr(mergeable_state: "behind", mergeable: false))

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
      .with("acme/widgets", 99, bypass_cache: true)
      .and_return(pr)

    described_class.perform_now(external.id)
  end
end
