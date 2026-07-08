require "rails_helper"

RSpec.describe PollAllInputSourcesJob do
  let(:user) { Factories.user(github_token: "ghp_test_token") }

  it "enqueues PollInputSourceJob for each active enabled source" do
    repo1 = Factories.repository(user: user, polling_enabled: true)
    repo2 = Factories.repository(user: user, polling_enabled: true)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollInputSourceJob)
      .with(repo1.github_input_source.id)
      .and have_enqueued_job(PollInputSourceJob)
      .with(repo2.github_input_source.id)
  end

  it "skips sources for archived repositories" do
    repo = Factories.repository(user: user, polling_enabled: true)
    repo.archive!

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollInputSourceJob)
  end

  it "skips sources where polling_enabled is false" do
    repo = Factories.repository(user: user, polling_enabled: false)
    repo.github_input_source.update!(polling_enabled: false)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollInputSourceJob)
  end

  it "does nothing when polling is globally paused" do
    AppSetting.first_or_create.update!(polling_paused: true)
    Factories.repository(user: user, polling_enabled: true)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollInputSourceJob)
  ensure
    AppSetting.first_or_create.update!(polling_paused: false)
  end
end
