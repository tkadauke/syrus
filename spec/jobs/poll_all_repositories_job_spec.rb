require "rails_helper"

RSpec.describe PollAllRepositoriesJob do
  it "enqueues PollRepositoryJob for each polling-enabled repository" do
    enabled = Factories.repository(polling_enabled: true)
    other_enabled = Factories.repository(polling_enabled: true)
    Factories.repository(polling_enabled: false)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollRepositoryJob).exactly(2).times
      .and have_enqueued_job(PollRepositoryJob).with(enabled.id)
      .and have_enqueued_job(PollRepositoryJob).with(other_enabled.id)
  end

  it "skips archived repositories even if polling_enabled is true" do
    archived = Factories.repository(polling_enabled: true)
    archived.archive!
    expect(archived.polling_enabled).to be false   # archive! turned it off too
    archived.update_column(:polling_enabled, true) # simulate inconsistent state to prove the scope filters

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollRepositoryJob)
  end

  it "skips repositories whose GitHub App installation is rate-limited" do
    user = Factories.user
    repo = Factories.repository(user: user, polling_enabled: true)
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
    }.not_to have_enqueued_job(PollRepositoryJob).with(repo.id)
  end
end
