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
    allow(client).to receive(:compare_commits)
      .with("acme/widgets", "main", "syrus/emergency-1")
      .and_return(commits: commits, merge_base_sha: "base", status: commits.present? ? "ahead" : nil)
  end

  def stub_open_pr(number: 9)
    allow(client).to receive(:open_pull_request_for_head).and_return(nil)
    allow(client).to receive(:create_pull_request).and_return(OpenStruct.new(number: number))
  end

  def stub_mergeable_pr(number: 9, mergeable: true)
    allow(client).to receive(:pull_request)
      .with("acme/widgets", number, bypass_cache: true)
      .and_return(OpenStruct.new(mergeable: mergeable))
  end

  def stub_merge(number: 9, merged: true, sha: "mergedsha123")
    allow(client).to receive(:merge_pull_request)
      .with("acme/widgets", number, hash_including(merge_method: "rebase"))
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

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_success
      expect(result.pr_number).to eq(9)
      expect(client).to have_received(:create_pull_request)
        .with("acme/widgets", hash_including(base: "main", head: "acme:syrus/emergency-1"))
      expect(client).to have_received(:merge_pull_request)
        .with("acme/widgets", 9, hash_including(merge_method: "rebase"))

      job.reload
      expect(job).to be_closed
      expect(job.pr_number).to eq(9)
      expect(job.landed_sha).to eq("mergedsha123")
      expect(job.closure_reason).to eq("emergency_landed")
      expect(job.emergency_landed_at).to be_present
      expect(job.emergency_landed_by_user_id).to eq(owner.id)
      expect(job.emergency_landed_by_membership_tier).to eq("admin")
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

    it "refuses when the Job is not in coding state" do
      job.update!(state: "implemented")

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/coding mode/i)
    end

    it "refuses when the linked chat is not in Coding Mode" do
      chat_session.update!(mode: "planning")

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/coding mode/i)
    end

    it "refuses when the workspace has no pushed commits ahead of the default branch" do
      stub_ahead_commits(commits: [])

      result = described_class.land(job: job, user: owner, client: client)

      expect(result).to be_refused
      expect(result.message).to match(/no pushed commits/i)
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
