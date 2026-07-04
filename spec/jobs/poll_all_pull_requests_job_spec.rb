require "rails_helper"

RSpec.describe PollAllPullRequestsJob do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  it "fans out to PollPullRequestJob only over open Jobs that have a Syrus PR" do
    open_with_pr = Factories.job(repository: repo, issue_number: 1).tap do |j|
      j.update!(pr_number: 1)
    end
    Factories.job(repository: repo, issue_number: 2)  # open, no PR
    closed_with_pr = Factories.job(repository: repo, issue_number: 3).tap do |j|
      j.update!(pr_number: 3)
      j.close_with_reason!("manual")
    end

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollPullRequestJob).with(open_with_pr.id).once

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollPullRequestJob).with(closed_with_pr.id)
  end

  it "fans out to PollExternalPrJob for open Jobs with only an external PR" do
    open_external_only = Factories.job(repository: repo, issue_number: 4).tap do |j|
      j.update!(external_pr_number: 10)
    end
    # Has both — PollPullRequestJob owns it, not PollExternalPrJob
    open_both = Factories.job(repository: repo, issue_number: 5).tap do |j|
      j.update!(pr_number: 5, external_pr_number: 11)
    end
    # Closed with external PR — must NOT be polled
    closed_external = Factories.job(repository: repo, issue_number: 6).tap do |j|
      j.update!(external_pr_number: 12)
      j.close_with_reason!("preempted")
    end

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollExternalPrJob).with(open_external_only.id).once

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollExternalPrJob).with(open_both.id)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollExternalPrJob).with(closed_external.id)
  end

  it "fans out to PollForkReviewPrJob for open Jobs in fork review mode (fork_review_pr_number set, no pr_number)" do
    upstream = Factories.repository(user: user)
    fork_in_review = Factories.job(repository: repo, issue_number: 7, target_repository: upstream).tap do |j|
      j.update!(fork_review_pr_number: 20)
    end
    # Upstream PR already created — PollPullRequestJob takes over, not PollForkReviewPrJob
    fork_upstream_pr_exists = Factories.job(repository: repo, issue_number: 8, target_repository: upstream).tap do |j|
      j.update!(fork_review_pr_number: 21, pr_number: 22)
    end
    # Closed — must NOT be polled
    closed_fork = Factories.job(repository: repo, issue_number: 9, target_repository: upstream).tap do |j|
      j.update!(fork_review_pr_number: 23)
      j.close_with_reason!("manual")
    end

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollForkReviewPrJob).with(fork_in_review.id).once

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollForkReviewPrJob).with(fork_upstream_pr_exists.id)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollForkReviewPrJob).with(closed_fork.id)
  end
end
