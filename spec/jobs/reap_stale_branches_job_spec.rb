require "rails_helper"

RSpec.describe ReapStaleBranchesJob do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:for).and_return(client)
    allow(client).to receive(:delete_branch)
  end

  def closed_job(branch_name:, finished_at:, branch_deleted_at: nil)
    job = Factories.job_record(
      user: user,
      repository: repository,
      branch_name: branch_name,
      state: "closed"
    )
    job.update_columns(finished_at: finished_at, branch_deleted_at: branch_deleted_at)
    job
  end

  describe "#perform" do
    it "deletes branches of closed jobs past the grace period and stamps branch_deleted_at" do
      job = closed_job(branch_name: "syrus/issue-1", finished_at: 24.hours.ago)

      described_class.perform_now

      expect(client).to have_received(:delete_branch).with("acme/widgets", "syrus/issue-1")
      expect(job.reload.branch_deleted_at).to be_present
    end

    it "skips jobs closed less than 23 hours ago" do
      closed_job(branch_name: "syrus/issue-2", finished_at: 22.hours.ago)

      described_class.perform_now

      expect(client).not_to have_received(:delete_branch)
    end

    it "skips jobs where branch_deleted_at is already set" do
      closed_job(branch_name: "syrus/issue-3", finished_at: 24.hours.ago, branch_deleted_at: 1.hour.ago)

      described_class.perform_now

      expect(client).not_to have_received(:delete_branch)
    end

    it "skips jobs with no branch_name" do
      closed_job(branch_name: nil, finished_at: 24.hours.ago)

      described_class.perform_now

      expect(client).not_to have_received(:delete_branch)
    end

    it "processes multiple eligible jobs in a single run" do
      a = closed_job(branch_name: "syrus/issue-4", finished_at: 25.hours.ago)
      b = closed_job(branch_name: "syrus/issue-5", finished_at: 30.hours.ago)

      described_class.perform_now

      expect(client).to have_received(:delete_branch).with("acme/widgets", "syrus/issue-4")
      expect(client).to have_received(:delete_branch).with("acme/widgets", "syrus/issue-5")
      expect(a.reload.branch_deleted_at).to be_present
      expect(b.reload.branch_deleted_at).to be_present
    end

    it "continues processing remaining jobs when one deletion fails" do
      a = closed_job(branch_name: "syrus/issue-6", finished_at: 24.hours.ago)
      b = closed_job(branch_name: "syrus/issue-7", finished_at: 24.hours.ago)

      call_count = 0
      allow(client).to receive(:delete_branch) do |_repo, branch|
        call_count += 1
        raise "network error" if branch == a.branch_name
      end

      expect { described_class.perform_now }.not_to raise_error

      expect(call_count).to eq(2)
      expect(a.reload.branch_deleted_at).to be_nil
      expect(b.reload.branch_deleted_at).to be_present
    end
  end
end
