require "rails_helper"

RSpec.describe Job::ApprovalPropagator do
  let(:user) { Factories.user(email_address: "operator@example.com") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job(repository: repository, issue_number: 42) }
  let(:read_client) { instance_double(GithubClient) }

  describe ".approve" do
    it "posts a review as the approving user's own PAT when their login differs from the PR author" do
      user.update!(github_token: "operator-pat")
      job.update!(pr_number: 123)
      pat_client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      allow(read_client).to receive(:pull_request)
        .with("acme/widgets", 123, bypass_cache: true)
        .and_return(Struct.new(:user).new(Struct.new(:login).new("pr-author")))
      allow(GithubClient).to receive(:for_user).with(user, repository: repository).and_return(pat_client)
      allow(pat_client).to receive(:authenticated_login).and_return("operator-login")
      expect(pat_client).to receive(:create_pr_review)
        .with("acme/widgets", 123, event: "APPROVE", body: "Approved by @operator@example.com via Syrus.")
        .and_return(Struct.new(:id).new(987))

      result = described_class.approve(job, user: user)

      expect(result).to be_success
      expect(result.message).to eq("GitHub review left.")
      expect(job.reload.approval_evidence).to include("github_review_id" => 987)
    end

    it "posts as the App/bot when the approving user is the PR's literal author, crediting them in the body" do
      AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
      installation = Factories.installation(user: user, account_login: "acme")
      repository.update!(installation: installation)
      user.update!(github_token: "operator-pat")
      job.update!(pr_number: 123)
      pat_client = instance_double(GithubClient)
      bot_client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      allow(read_client).to receive(:pull_request)
        .with("acme/widgets", 123, bypass_cache: true)
        .and_return(Struct.new(:user).new(Struct.new(:login).new("operator-login")))
      allow(GithubClient).to receive(:for_user).with(user, repository: repository).and_return(pat_client)
      allow(pat_client).to receive(:authenticated_login).and_return("operator-login")
      allow(GithubClient).to receive(:for).with(repository: repository, user: nil).and_return(bot_client)
      expect(bot_client).to receive(:create_pr_review)
        .with("acme/widgets", 123, event: "APPROVE", body: "Approved by @operator@example.com via Syrus.")
        .and_return(Struct.new(:id).new(555))

      result = described_class.approve(job, user: user)

      expect(result).to be_success
      expect(job.reload.approval_evidence).to include("github_review_id" => 555)
    end

    it "falls back to the App/bot when the approver has no connected PAT and isn't the PR author" do
      AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
      installation = Factories.installation(user: user, account_login: "acme")
      repository.update!(installation: installation)
      job.update!(pr_number: 123)
      bot_client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      allow(read_client).to receive(:pull_request)
        .with("acme/widgets", 123, bypass_cache: true)
        .and_return(Struct.new(:user).new(Struct.new(:login).new("someone-else")))
      expect(GithubClient).not_to receive(:for_user)
      allow(GithubClient).to receive(:for).with(repository: repository, user: nil).and_return(bot_client)
      expect(bot_client).to receive(:create_pr_review)
        .with("acme/widgets", 123, event: "APPROVE", body: "Approved by @operator@example.com via Syrus.")
        .and_return(Struct.new(:id).new(111))

      result = described_class.approve(job, user: user)

      expect(result).to be_success
      expect(job.reload.approval_evidence).to include("github_review_id" => 111)
    end

    it "skips gracefully when no usable credential exists at all" do
      job.update!(pr_number: 123)
      expect(GithubClient).not_to receive(:for)
      expect(GithubClient).not_to receive(:for_user)

      result = described_class.approve(job, user: user)

      expect(result).to be_skipped
      expect(result.message).to be_nil
      expect(job.reload.approval_evidence).to eq({})
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
      AppSetting.current.update!(github_app_id: 123, github_app_slug: "operator-syrus")
      installation = Factories.installation(user: user, account_login: "acme")
      repository.update!(installation: installation)
      job.update!(pr_number: 123)
      bot_client = instance_double(GithubClient)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      allow(read_client).to receive(:pull_request)
        .with("acme/widgets", 123, bypass_cache: true)
        .and_return(Struct.new(:user).new(Struct.new(:login).new("someone-else")))
      allow(GithubClient).to receive(:for).with(repository: repository, user: nil).and_return(bot_client)
      allow(bot_client).to receive(:create_pr_review)
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
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      expect(read_client).to receive(:dismiss_pr_review)
        .with("acme/widgets", 123, 555, message: "Dismissed via Syrus.")

      result = described_class.dismiss(job, 555, user: user)

      expect(result).to be_success
      expect(result.message).to eq("GitHub review dismissed.")
    end

    it "looks up the approved review and dismisses it when no review id was captured" do
      job.update!(pr_number: 123)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      expect(read_client).to receive(:pr_reviews).with("acme/widgets", 123).and_return([
        Struct.new(:id, :state).new(111, "COMMENTED"),
        Struct.new(:id, :state).new(222, "APPROVED")
      ])
      expect(read_client).to receive(:dismiss_pr_review)
        .with("acme/widgets", 123, 222, message: "Dismissed via Syrus.")

      result = described_class.dismiss(job, nil, user: user)

      expect(result).to be_success
      expect(result.message).to eq("GitHub review dismissed.")
    end

    it "skips when no review id was captured and no APPROVED review is found" do
      job.update!(pr_number: 123)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      expect(read_client).to receive(:pr_reviews).with("acme/widgets", 123).and_return([
        Struct.new(:id, :state).new(111, "COMMENTED")
      ])
      expect(read_client).not_to receive(:dismiss_pr_review)

      result = described_class.dismiss(job, nil, user: user)

      expect(result).to be_skipped
    end

    it "skips the lookup entirely when a review id was already captured" do
      job.update!(pr_number: 123)
      allow(GithubClient).to receive(:for).with(repository: repository, user: user).and_return(read_client)
      expect(read_client).not_to receive(:pr_reviews)
      expect(read_client).to receive(:dismiss_pr_review)
        .with("acme/widgets", 123, 555, message: "Dismissed via Syrus.")

      result = described_class.dismiss(job, 555, user: user)

      expect(result).to be_success
    end
  end
end
