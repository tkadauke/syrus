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

  it "stays within the PR feedback poll budget and keeps recent Jobs first" do
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    Array.new(GithubPollingBudget::PR_FEEDBACK_LIMIT + 5) do |index|
      Factories.job(repository: repo, issue_number: 100 + index).tap do |job|
        job.update_columns(pr_number: 100 + index, updated_at: Time.current)
      end
    end
    recent = Factories.job(repository: repo, issue_number: 999)
    recent.update!(pr_number: 999)

    described_class.perform_now

    poll_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |entry| entry[:job] == PollPullRequestJob }
    expect(poll_jobs.count).to eq(GithubPollingBudget::PR_FEEDBACK_LIMIT)
    expect(PollPullRequestJob).to have_been_enqueued.with(recent.id)
  end

  it "skips PR feedback polling while the repository's GitHub App installation is rate-limited" do
    installation = Factories.installation(
      user: user,
      account_login: repo.owner,
      gh_rate_limit_remaining: 0,
      gh_rate_limit_limit: 5_000,
      gh_rate_limit_reset_at: 30.minutes.from_now,
      gh_rate_limit_resource: "core",
      gh_rate_limit_observed_at: Time.current
    )
    repo.update!(installation: installation)
    job = Factories.job(repository: repo, issue_number: 10)
    job.update!(pr_number: 10)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollPullRequestJob).with(job.id)
  end

  it "fans out to PollExternalPrJob for open Jobs with only an external PR" do
    open_external_only = Factories.job(repository: repo, issue_number: 4).tap do |j|
      j.update!(external_pr_number: 10)
    end
    # Non-external_pr kind with both — PollPullRequestJob owns it, PollExternalPrJob skips it
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

  it "skips external and fork PR polling while the repository's GitHub App installation is rate-limited" do
    installation = Factories.installation(
      user: user,
      account_login: repo.owner,
      gh_rate_limit_remaining: 0,
      gh_rate_limit_reset_at: 30.minutes.from_now,
      gh_rate_limit_observed_at: Time.current
    )
    repo.update!(installation: installation)
    external = Factories.job(repository: repo, issue_number: 11)
    external.update!(external_pr_number: 11)
    fork = Factories.job(repository: repo, issue_number: 12)
    fork.update!(fork_review_pr_number: 12)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollExternalPrJob).with(external.id)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollForkReviewPrJob).with(fork.id)
  end

  it "fans out to PollExternalPrJob for external_pr kind Jobs even when pr_number is also set" do
    # external_pr kind — polled by PollExternalPrJob regardless of pr_number
    external_pr_no_syrus_pr = Job.create!(user: user, repository: repo,
                                          kind: "external_pr", state: "implemented",
                                          external_pr_number: 40)
    external_pr_with_syrus_pr = Job.create!(user: user, repository: repo,
                                            kind: "external_pr", state: "implemented",
                                            external_pr_number: 41)
    external_pr_with_syrus_pr.update_columns(pr_number: 55)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollExternalPrJob).with(external_pr_no_syrus_pr.id).once
      .and have_enqueued_job(PollExternalPrJob).with(external_pr_with_syrus_pr.id).once
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
