require "rails_helper"

RSpec.describe BugReports::Router do
  let(:user) { Factories.user(github_token: "ghp_test") }

  before do
    AppSetting.current.update!(report_issue_repo_slug: "target-org/syrus")
  end

  describe ".mode_for" do
    it "returns nil when user is nil" do
      expect(described_class.mode_for(user: nil)).to be_nil
    end

    it "returns :direct_job when a system-wide repository record exists for the slug" do
      Factories.repository(user: Factories.user, owner: "target-org", name: "syrus")
      expect(described_class.mode_for(user: user)).to eq(:direct_job)
    end

    it "returns :direct_job when the user has a fork of the target repo" do
      Factories.repository(
        user: user, owner: "my-fork", name: "syrus",
        upstream_owner: "target-org", upstream_name: "syrus"
      )
      expect(described_class.mode_for(user: user)).to eq(:direct_job)
    end

    it "returns :github_issue when no matching repo or fork exists" do
      expect(described_class.mode_for(user: user)).to eq(:github_issue)
    end
  end

  describe "#mode" do
    it "prefers system_repo over user_fork_repo" do
      system = Factories.repository(user: Factories.user, owner: "target-org", name: "syrus")
      Factories.repository(
        user: user, owner: "fork-org", name: "syrus",
        upstream_owner: "target-org", upstream_name: "syrus"
      )
      router = described_class.new(user: user)
      expect(router.mode).to eq(:direct_job)
    end
  end

  describe "#call — direct_job path" do
    let!(:repo) { Factories.repository(user: Factories.user, owner: "target-org", name: "syrus") }

    it "creates a Job and returns a result with job set" do
      expect {
        result = described_class.new(user: user).call(title: "T", description: "D")
        expect(result.job).to be_a(Job)
        expect(result.issue_url).to be_nil
        expect(result.error_code).to be_nil
        expect(result.mode).to eq(:direct_job)
      }.to change(Job, :count).by(1)
    end

    it "routes to the user's fork when no system repo matches" do
      repo.destroy!
      fork = Factories.repository(
        user: user, owner: "fork-org", name: "syrus",
        upstream_owner: "target-org", upstream_name: "syrus"
      )

      result = described_class.new(user: user).call(title: "Fork bug", description: "Found it.")
      expect(result.job).to be_present
      expect(result.job.repository).to eq(fork)
    end
  end

  describe "#call — github_issue path" do
    def stub_github_issue
      stub_request(:post, "https://api.github.com/repos/target-org/syrus/issues")
        .to_return(
          status: 201,
          headers: { "Content-Type" => "application/json" },
          body: { number: 10, html_url: "https://github.com/target-org/syrus/issues/10" }.to_json
        )
    end

    it "returns a result with issue_url set" do
      stub_github_issue
      result = described_class.new(user: user).call(title: "Issue title", description: "Details")
      expect(result.issue_url).to eq("https://github.com/target-org/syrus/issues/10")
      expect(result.job).to be_nil
      expect(result.mode).to eq(:github_issue)
    end

    it "returns error_code github_token_required when the user has no GitHub token" do
      user_no_token = Factories.user
      result = described_class.new(user: user_no_token).call(title: "T", description: "D")
      expect(result.error_code).to eq("github_token_required")
      expect(result.issue_url).to be_nil
    end
  end
end
