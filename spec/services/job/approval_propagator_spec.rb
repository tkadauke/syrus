require "rails_helper"

RSpec.describe Job::ApprovalPropagator do
  let(:user) { Factories.user(email_address: "operator@example.com") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }
  let(:client) { instance_double(GithubClient) }

  describe ".approve" do
    it "files an APPROVE review and records the review id" do
      job.update!(pr_number: 123)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
      expect(client).to receive(:create_pr_review)
        .with("acme/widgets", 123, event: "APPROVE", body: "Approved by @operator@example.com via Syrus.")
        .and_return(Struct.new(:id).new(987))

      result = described_class.approve(job, user: user)

      expect(result).to be_success
      expect(result.message).to eq("GitHub review left.")
      expect(job.reload.approval_evidence).to include("github_review_id" => 987)
    end

    it "skips when the repository opts out" do
      repository.update!(approval_propagates_to_github: false)
      job.update!(pr_number: 123)
      expect(GithubClient).not_to receive(:for)

      result = described_class.approve(job, user: user)

      expect(result).to be_skipped
      expect(result.message).to be_nil
    end

    it "skips when the job has no PR" do
      expect(GithubClient).not_to receive(:for)

      result = described_class.approve(job, user: user)

      expect(result).to be_skipped
    end

    it "swallows Octokit errors and returns an operator-facing note" do
      job.update!(pr_number: 123)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
      allow(client).to receive(:create_pr_review)
        .and_raise(Octokit::UnprocessableEntity.new(body: { message: "Pull request author can't approve their own pull request" }))

      result = described_class.approve(job, user: user)

      expect(result).to be_failure
      expect(result.message).to include("GitHub review failed")
      expect(job.reload.approval_evidence).to eq({})
    end
  end

  describe ".dismiss" do
    it "dismisses a recorded GitHub review" do
      job.update!(pr_number: 123)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(client)
      expect(client).to receive(:dismiss_pr_review)
        .with("acme/widgets", 123, 555, message: "Dismissed via Syrus.")

      result = described_class.dismiss(job, 555, user: user)

      expect(result).to be_success
      expect(result.message).to eq("GitHub review dismissed.")
    end
  end
end
