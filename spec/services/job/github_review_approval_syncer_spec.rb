require "rails_helper"
require "ostruct"

RSpec.describe Job::GithubReviewApprovalSyncer do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job(user: user, repository: repository, pr_number: 7) }

  def review(state: "APPROVED", login: "reviewer", submitted_at: 1.hour.ago.iso8601)
    OpenStruct.new(
      state: state,
      user: OpenStruct.new(login: login),
      submitted_at: submitted_at,
      html_url: "https://github.com/acme/widgets/pull/7#pullrequestreview-1"
    )
  end

  describe ".sync" do
    it "creates a JobApproval for an APPROVED review when the reviewer is a Syrus user" do
      reviewer = Factories.user(github_handle: "reviewer")
      submitted = 2.hours.ago

      expect {
        described_class.sync(job: job, reviews: [ review(login: "reviewer", submitted_at: submitted.iso8601) ])
      }.to change { job.job_approvals.count }.by(1)

      approval = job.job_approvals.find_by(user: reviewer)
      expect(approval).to be_present
      expect(approval.approved_at).to be_within(1.second).of(submitted)
    end

    it "creates approvals for multiple reviewers" do
      alice = Factories.user(github_handle: "alice")
      bob   = Factories.user(github_handle: "bob")

      described_class.sync(job: job, reviews: [
        review(login: "alice", submitted_at: 3.hours.ago.iso8601),
        review(login: "bob",   submitted_at: 2.hours.ago.iso8601)
      ])

      expect(job.job_approvals.map(&:user)).to contain_exactly(alice, bob)
    end

    it "skips reviews whose state is not APPROVED" do
      Factories.user(github_handle: "reviewer")

      expect {
        described_class.sync(job: job, reviews: [
          review(state: "DISMISSED"),
          review(state: "CHANGES_REQUESTED"),
          review(state: "COMMENTED"),
          review(state: "PENDING")
        ])
      }.not_to change { job.job_approvals.count }
    end

    it "skips a review when the reviewer has no Syrus account" do
      expect {
        described_class.sync(job: job, reviews: [ review(login: "outsider") ])
      }.not_to change { job.job_approvals.count }
    end

    it "is idempotent: does not duplicate an existing JobApproval" do
      reviewer = Factories.user(github_handle: "reviewer")
      job.job_approvals.create!(user: reviewer, approved_at: 1.hour.ago)

      expect {
        described_class.sync(job: job, reviews: [ review(login: "reviewer") ])
      }.not_to change { job.job_approvals.count }
    end

    it "does not create a record for a reviewer whose ApprovalPropagator already created one" do
      # When Syrus pushes a review to GitHub via ApprovalPropagator, the
      # inbound sync path must not add a duplicate row.
      reviewer = Factories.user(github_handle: "reviewer")
      job.job_approvals.create!(user: reviewer, approved_at: Time.current)

      expect {
        described_class.sync(job: job, reviews: [ review(login: "reviewer") ])
      }.not_to change { job.job_approvals.count }
    end

    it "falls back to Time.current when submitted_at is blank" do
      reviewer = Factories.user(github_handle: "reviewer")
      r = OpenStruct.new(state: "APPROVED", user: OpenStruct.new(login: "reviewer"), submitted_at: nil)

      freeze_time do
        described_class.sync(job: job, reviews: [ r ])
        expect(job.job_approvals.find_by(user: reviewer).approved_at).to be_within(1.second).of(Time.current)
      end
    end

    it "skips a review when the user login is blank" do
      r = OpenStruct.new(state: "APPROVED", user: OpenStruct.new(login: ""), submitted_at: 1.hour.ago.iso8601)

      expect {
        described_class.sync(job: job, reviews: [ r ])
      }.not_to change { job.job_approvals.count }
    end
  end
end
