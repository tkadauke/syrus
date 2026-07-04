require "rails_helper"

RSpec.describe ForkReviewApprover do
  let(:user) { Factories.user }
  let(:upstream) { Factories.repository(user: user, owner: "upstream-org", name: "widgets") }
  let(:fork_repo) { Factories.repository(user: user, owner: "acme", name: "widgets-fork") }
  let(:job) do
    j = Factories.job(repository: fork_repo, issue_number: 42, target_repository: upstream)
    j.update!(branch_name: "syrus/issue-42-#{j.id}", fork_review_pr_number: 7, state: "implemented")
    j
  end

  let(:fork_client) { instance_double(GithubClient) }
  let(:upstream_client) { instance_double(GithubClient) }
  let(:upstream_pr_url) { "https://api.github.com/repos/upstream-org/widgets/pulls" }

  def stub_close_fork_pr
    allow(fork_client).to receive(:close_pull_request)
      .with(fork_repo.slug, 7)
  end

  def stub_open_upstream_pr(pr_number:)
    allow(GithubClient).to receive(:for)
      .with(repository: upstream, user: user)
      .and_return(upstream_client)
    opener = instance_double(PullRequestOpener, open: pr_number)
    allow(PullRequestOpener).to receive(:new)
      .with(upstream, client: upstream_client, head_repository: fork_repo)
      .and_return(opener)
    opener
  end

  describe "#call" do
    it "closes the fork review PR, opens the upstream PR, and saves pr_number" do
      stub_close_fork_pr
      stub_open_upstream_pr(pr_number: 99)

      described_class.new(job, fork_client: fork_client).call(
        review_url: "https://github.com/acme/widgets-fork/pull/7#review-1",
        fork_pr_merged: false
      )

      job.reload
      expect(job.pr_number).to eq(99)
      expect(job.pr_repository_id).to eq(upstream.id)
      expect(fork_client).to have_received(:close_pull_request).with(fork_repo.slug, 7)
    end

    it "skips closing the fork PR when fork_pr_merged: true (accidental merge)" do
      stub_open_upstream_pr(pr_number: 100)
      expect(fork_client).not_to receive(:close_pull_request)

      described_class.new(job, fork_client: fork_client).call(
        review_url: "https://github.com/acme/widgets-fork/pull/7",
        fork_pr_merged: true
      )

      expect(job.reload.pr_number).to eq(100)
    end

    it "is idempotent when pr_number is already set" do
      job.update!(pr_number: 77)
      expect(fork_client).not_to receive(:close_pull_request)
      expect(PullRequestOpener).not_to receive(:new)

      described_class.new(job, fork_client: fork_client).call(
        review_url: "https://github.com/acme/widgets-fork/pull/7#review-1",
        fork_pr_merged: false
      )

      expect(job.reload.pr_number).to eq(77)
    end

    it "uses the latest succeeded workflow's pr_title artifact for the upstream PR" do
      workflow = job.workflows.last
      workflow.set_artifact!("pr_title", "Add greeting helper")
      workflow.set_artifact!("pr_body", "This adds a greeting.")
      workflow.update!(state: "succeeded")

      stub_close_fork_pr
      opener = stub_open_upstream_pr(pr_number: 101)

      described_class.new(job, fork_client: fork_client).call(
        review_url: "review-url",
        fork_pr_merged: false
      )

      expect(opener).to have_received(:open).with(
        branch: job.branch_name,
        title: "Add greeting helper",
        body: a_string_including("This adds a greeting.", "fork staging PR"),
        # no job: keyword — uses upstream default branch
      )
    end

    context "with self review policy" do
      before do
        fork_repo.update!(review_policy: "self")
        stub_close_fork_pr
        stub_open_upstream_pr(pr_number: 102)
      end

      it "auto-approves the job for landing" do
        expect {
          described_class.new(job, fork_client: fork_client).call(
            review_url: "review-url",
            fork_pr_merged: false
          )
        }.to change { job.reload.state }.from("implemented").to("approved")
      end
    end

    context "with two_person review policy" do
      before do
        fork_repo.update!(review_policy: "two_person")
        stub_close_fork_pr
        stub_open_upstream_pr(pr_number: 103)
      end

      it "does not auto-approve the job for landing" do
        described_class.new(job, fork_client: fork_client).call(
          review_url: "review-url",
          fork_pr_merged: false
        )

        expect(job.reload.state).to eq("implemented")
      end

      it "creates a JobApproval for the job owner when reviewer github_handle cannot be matched" do
        expect {
          described_class.new(job, fork_client: fork_client).call(
            review_url: "review-url",
            reviewer_github_handle: nil,
            fork_pr_merged: false
          )
        }.to change { job.job_approvals.count }.by(1)

        expect(job.job_approvals.last.user).to eq(job.owner_user)
      end

      it "creates a JobApproval for the matched Syrus user when reviewer github_handle is known" do
        reviewer = Factories.user(github_handle: "alice-dev")

        expect {
          described_class.new(job, fork_client: fork_client).call(
            review_url: "review-url",
            reviewer_github_handle: "alice-dev",
            fork_pr_merged: false
          )
        }.to change { job.job_approvals.count }.by(1)

        expect(job.job_approvals.last.user).to eq(reviewer)
      end

      it "falls back to job owner when reviewer github_handle doesn't match any Syrus user" do
        expect {
          described_class.new(job, fork_client: fork_client).call(
            review_url: "review-url",
            reviewer_github_handle: "unknown-person",
            fork_pr_merged: false
          )
        }.to change { job.job_approvals.count }.by(1)

        expect(job.job_approvals.last.user).to eq(job.owner_user)
      end

      it "is idempotent on repeated calls (does not duplicate JobApproval)" do
        described_class.new(job, fork_client: fork_client).call(
          review_url: "review-url",
          reviewer_github_handle: nil,
          fork_pr_merged: false
        )

        expect {
          described_class.new(job, fork_client: fork_client).call(
            review_url: "review-url",
            reviewer_github_handle: nil,
            fork_pr_merged: false
          )
        }.not_to change { job.job_approvals.count }
      end
    end

    context "with final_say review policy" do
      before do
        fork_repo.update!(review_policy: "final_say")
        stub_close_fork_pr
        stub_open_upstream_pr(pr_number: 105)
      end

      it "creates a JobApproval for the fork PR approver (owner fallback)" do
        expect {
          described_class.new(job, fork_client: fork_client).call(
            review_url: "review-url",
            reviewer_github_handle: nil,
            fork_pr_merged: false
          )
        }.to change { job.job_approvals.count }.by(1)
      end

      it "does not auto-approve the job for landing" do
        described_class.new(job, fork_client: fork_client).call(
          review_url: "review-url",
          fork_pr_merged: false
        )

        expect(job.reload.state).to eq("implemented")
      end
    end

    it "continues opening the upstream PR even if closing the fork PR fails" do
      allow(fork_client).to receive(:close_pull_request).and_raise(Octokit::NotFound)
      stub_open_upstream_pr(pr_number: 104)

      described_class.new(job, fork_client: fork_client).call(
        review_url: "review-url",
        fork_pr_merged: false
      )

      expect(job.reload.pr_number).to eq(104)
    end
  end
end
