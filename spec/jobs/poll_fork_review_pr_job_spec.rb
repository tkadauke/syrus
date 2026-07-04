require "rails_helper"

RSpec.describe PollForkReviewPrJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:upstream) { Factories.repository(user: user, owner: "upstream-org", name: "widgets") }
  let(:fork_repo) { Factories.repository(user: user, owner: "acme", name: "widgets-fork") }
  let(:job) do
    j = Factories.job(repository: fork_repo, issue_number: 42, target_repository: upstream)
    j.update!(branch_name: "syrus/issue-42-#{j.id}", fork_review_pr_number: 7)
    j.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    j
  end

  let(:fork_pr_url) { "https://api.github.com/repos/acme/#{fork_repo.name}/pulls/7" }
  let(:reviews_url) { "https://api.github.com/repos/acme/#{fork_repo.name}/pulls/7/reviews" }

  def stub_fork_pr(state: "open", merged: false)
    stub_request(:get, fork_pr_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: {
        number: 7,
        state: state,
        merged: merged,
        html_url: "https://github.com/acme/#{fork_repo.name}/pull/7"
      }.to_json
    )
  end

  def stub_reviews(reviews = [])
    stub_request(:get, reviews_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: reviews.to_json
    )
  end

  it "does nothing when the job has no fork_review_pr_number" do
    other_job = Factories.job(repository: fork_repo, issue_number: 99)
    expect(ForkReviewApprover).not_to receive(:new)
    described_class.perform_now(other_job.id)
  end

  it "does nothing when the job already has an upstream pr_number" do
    job.update!(pr_number: 50)
    expect(ForkReviewApprover).not_to receive(:new)
    described_class.perform_now(job.id)
  end

  it "does nothing when the job is closed" do
    job.close_with_reason!("manual")
    expect(ForkReviewApprover).not_to receive(:new)
    described_class.perform_now(job.id)
  end

  it "calls ForkReviewApprover with fork_pr_merged: true on accidental merge" do
    stub_fork_pr(state: "closed", merged: true)
    approver = instance_double(ForkReviewApprover)
    expect(ForkReviewApprover).to receive(:new).with(
      job,
      fork_client: instance_of(GithubClient)
    ).and_return(approver)
    expect(approver).to receive(:call).with(
      review_url: "https://github.com/acme/#{fork_repo.name}/pull/7",
      fork_pr_merged: true
    )

    described_class.perform_now(job.id)
  end

  it "does nothing when the fork PR is closed but not merged" do
    stub_fork_pr(state: "closed", merged: false)
    expect(ForkReviewApprover).not_to receive(:new)

    described_class.perform_now(job.id)
  end

  it "calls ForkReviewApprover when a GitHub review approval is present" do
    stub_fork_pr
    stub_reviews([
      {
        state: "APPROVED",
        submitted_at: 1.hour.ago.iso8601,
        html_url: "https://github.com/acme/#{fork_repo.name}/pull/7#pullrequestreview-42"
      }
    ])
    approver = instance_double(ForkReviewApprover)
    expect(ForkReviewApprover).to receive(:new).with(
      job,
      fork_client: instance_of(GithubClient)
    ).and_return(approver)
    expect(approver).to receive(:call).with(
      review_url: "https://github.com/acme/#{fork_repo.name}/pull/7#pullrequestreview-42",
      fork_pr_merged: false
    )

    described_class.perform_now(job.id)
  end

  it "does nothing when the open PR has no approvals" do
    stub_fork_pr
    stub_reviews([{ state: "COMMENTED", submitted_at: 1.hour.ago.iso8601 }])
    expect(ForkReviewApprover).not_to receive(:new)

    described_class.perform_now(job.id)
  end

  it "does nothing when the open PR has no reviews at all" do
    stub_fork_pr
    stub_reviews([])
    expect(ForkReviewApprover).not_to receive(:new)

    described_class.perform_now(job.id)
  end
end
