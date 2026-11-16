require "rails_helper"

RSpec.describe GithubSource::IssueCache do
  describe ".update_untagged_open_issue_count!" do
    it "updates the volatile repository count without invalidating stable dashboard chrome" do
      repository = Factories.repository(untagged_open_issue_count: 3)
      allow(App::DashboardChromeCache).to receive(:invalidate_all!)

      described_class.update_untagged_open_issue_count!(repository)

      expect(repository.reload.untagged_open_issue_count).to eq(0)
      expect(repository.untagged_open_issues_checked_at).to be_present
      expect(App::DashboardChromeCache).not_to have_received(:invalidate_all!)
    end
  end
end
