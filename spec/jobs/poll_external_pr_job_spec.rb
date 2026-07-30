require "rails_helper"

RSpec.describe PollExternalPrJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }

  # An open Job whose issue was preempted: external_pr_number set, no Syrus PR.
  let(:job) do
    j = Factories.job(repository: repository, issue_number: 42)
    # Stub the auto-created initial Run so the Job stays open without a real run.
    j.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    j.update!(external_pr_number: 9)
    j
  end

  let(:slug) { "acme/widgets" }
  let(:external_pr_url) { "https://api.github.com/repos/acme/widgets/pulls/9" }

  def stub_external_pr(state: "open", merged: false, merge_commit_sha: nil)
    body = { number: 9, state: state, merged: merged }
    body[:merge_commit_sha] = merge_commit_sha if merge_commit_sha
    stub_request(:get, external_pr_url).with(query: hash_including({})).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: body.to_json
    )
  end

  describe "close conditions" do
    it "closes the Job with external_pr_merged when the external PR is merged" do
      stub_external_pr(state: "closed", merged: true)
      expect { described_class.perform_now(job.id) }.to change { job.reload.state }.to("closed")
      expect(job.closure_reason).to eq("external_pr_merged")
    end

    it "stores merge_commit_sha as landed_sha when the external PR is merged" do
      stub_external_pr(state: "closed", merged: true, merge_commit_sha: "deadbeef1234")
      described_class.perform_now(job.id)
      expect(job.reload.landed_sha).to eq("deadbeef1234")
    end

    it "leaves landed_sha nil when merge_commit_sha is absent" do
      stub_external_pr(state: "closed", merged: true)
      described_class.perform_now(job.id)
      expect(job.reload.landed_sha).to be_nil
    end

    it "does not set landed_sha when the PR is only closed (not merged)" do
      stub_external_pr(state: "closed", merged: false)
      described_class.perform_now(job.id)
      expect(job.reload.landed_sha).to be_nil
    end

    it "closes the Job with external_pr_closed when the external PR is closed without merging" do
      stub_external_pr(state: "closed", merged: false)
      described_class.perform_now(job.id)
      expect(job.reload.closure_reason).to eq("external_pr_closed")
    end

    it "leaves the Job open when the external PR is still open" do
      stub_external_pr(state: "open", merged: false)
      expect { described_class.perform_now(job.id) }.not_to change { job.reload.state }
    end
  end

  describe "guards" do
    it "no-ops when the Job is already closed" do
      job.close_with_reason!("preempted")
      described_class.perform_now(job.id)
      # No GitHub call should be made
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end

    it "no-ops when the Job has no external_pr_number" do
      job.update!(external_pr_number: nil)
      described_class.perform_now(job.id)
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end

    it "no-ops when the Job also has a Syrus pr_number (handled by PollPullRequestJob)" do
      job.update!(pr_number: 7)
      described_class.perform_now(job.id)
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end

    it "no-ops for an archived repository" do
      repository.update!(archived_at: Time.current)
      described_class.perform_now(job.id)
      expect(WebMock).not_to have_requested(:get, external_pr_url)
    end
  end
end
