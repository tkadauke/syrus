require "rails_helper"

RSpec.describe GracePeriodExpiryJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    j = Factories.job(repository: repository, issue_number: 42)
    j.update!(
      branch_name: "syrus/issue-42-#{j.id}",
      pr_number: 7,
      needs_attention: true,
      needs_attention_reason: "upstream_pr_closed",
      needs_attention_since: 8.days.ago,
      grace_period_expires_at: 1.hour.ago
    )
    j.initial_run.tap { |r| r.start!; r.succeed!; r.save! }
    j
  end

  before do
    stub_request(:delete, /api\.github\.com\/repos\/.*\/git\/refs\/heads\//).to_return(
      status: 204, body: ""
    )
  end

  it "does nothing when the job is already closed" do
    job.close_with_reason!("manual")
    described_class.perform_now(job.id)
    expect(job.reload.closed?).to be true
  end

  it "does nothing when grace_period_expires_at is nil" do
    job.update!(grace_period_expires_at: nil)
    described_class.perform_now(job.id)
    expect(job.reload.state).not_to eq("closed")
  end

  it "does nothing when the grace period has not expired yet" do
    job.update!(grace_period_expires_at: 2.hours.from_now)
    described_class.perform_now(job.id)
    expect(job.reload.state).not_to eq("closed")
  end

  it "closes the job when the grace period has expired" do
    described_class.perform_now(job.id)
    expect(job.reload.state).to eq("closed")
    expect(job.reload.closure_reason).to eq("pr_closed")
  end

  it "clears grace_period_expires_at on the job after closing" do
    described_class.perform_now(job.id)
    expect(job.reload.grace_period_expires_at).to be_nil
  end

  it "deletes the branch on GitHub after closing" do
    delete_stub = stub_request(:delete, /api\.github\.com\/repos\/acme\/widgets\/git\/refs\/heads\/syrus/).to_return(status: 204, body: "")
    described_class.perform_now(job.id)
    expect(delete_stub).to have_been_requested
    expect(job.reload.branch_deleted_at).to be_present
  end

  it "does not raise when branch deletion fails" do
    stub_request(:delete, /api\.github\.com\/repos\/.*\/git\/refs\/heads\//).to_return(status: 422, body: "")
    expect { described_class.perform_now(job.id) }.not_to raise_error
    expect(job.reload.state).to eq("closed")
  end

  it "does nothing when the job does not exist" do
    expect { described_class.perform_now(999_999_999) }.not_to raise_error
  end
end
