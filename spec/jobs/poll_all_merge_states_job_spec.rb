require "rails_helper"

RSpec.describe PollAllMergeStatesJob do
  it "fans out to PollMergeStateJob for Syrus-authored PRs" do
    syrus_pr = Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")
    no_pr = Factories.job

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollMergeStateJob).with(syrus_pr.id)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(no_pr.id)
  end

  it "fans out to PollMergeStateJob for external PRs (preempted-Job ingest path)" do
    external = Factories.job
    external.update!(state: "closed", closure_reason: "preempted",
                     external_pr_number: 99, finished_at: Time.current)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollMergeStateJob).with(external.id)
  end

  it "does not fan out for closed Syrus-authored PRs" do
    closed = Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")
    closed.close!
    closed.save!

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(closed.id)
  end

  it "skips jobs whose repository GitHub App installation is rate-limited" do
    user = Factories.user
    repo = Factories.repository(user: user)
    installation = Factories.installation(
      user: user,
      account_login: repo.owner,
      gh_rate_limit_remaining: 0,
      gh_rate_limit_reset_at: 30.minutes.from_now,
      gh_rate_limit_observed_at: Time.current
    )
    repo.update!(installation: installation)
    job = Factories.job(repository: repo, pr_number: 17, branch_name: "syrus/issue-17")

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(job.id)
  end

  it "skips Jobs whose Repository is archived" do
    archived_repo = Factories.repository
    archived_repo.archive!
    archived_job = Factories.job(repository: archived_repo, pr_number: 11, branch_name: "syrus/x")

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMergeStateJob).with(archived_job.id)
  end

  it "is inert when polling is paused" do
    AppSetting.current.update!(polling_paused: true)
    Factories.job(pr_number: 7, branch_name: "syrus/issue-1-1")

    expect { described_class.perform_now }.not_to have_enqueued_job(PollMergeStateJob)
  ensure
    AppSetting.current.update!(polling_paused: false)
  end
end
