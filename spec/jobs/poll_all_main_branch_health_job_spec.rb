require "rails_helper"

RSpec.describe PollAllMainBranchHealthJob do
  it "enqueues PollMainBranchHealthJob for each active repository with health checks enabled" do
    r1 = Factories.repository
    r2 = Factories.repository
    archived = Factories.repository
    archived.archive!
    Factories.repository(main_branch_health_enabled: false)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollMainBranchHealthJob).exactly(2).times
      .and have_enqueued_job(PollMainBranchHealthJob).with(r1.id)
      .and have_enqueued_job(PollMainBranchHealthJob).with(r2.id)
  end

  it "skips repositories whose GitHub App installation is rate-limited" do
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

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMainBranchHealthJob).with(repo.id)
  end

  it "does nothing when polling is globally paused" do
    allow(AppSetting).to receive(:polling_paused?).and_return(true)
    Factories.repository

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMainBranchHealthJob)
  end
end
