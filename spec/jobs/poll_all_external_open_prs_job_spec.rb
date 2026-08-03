require "rails_helper"

RSpec.describe PollAllExternalOpenPrsJob do
  it "enqueues PollExternalOpenPrsJob for each repository with external_pr_ingestion_enabled" do
    enabled = Factories.repository(external_pr_ingestion_enabled: true)
    other_enabled = Factories.repository(external_pr_ingestion_enabled: true)
    Factories.repository(external_pr_ingestion_enabled: false)

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollExternalOpenPrsJob).exactly(2).times
      .and have_enqueued_job(PollExternalOpenPrsJob).with(enabled.id)
      .and have_enqueued_job(PollExternalOpenPrsJob).with(other_enabled.id)
  end

  it "skips archived repositories even if external_pr_ingestion_enabled is true" do
    repo = Factories.repository(external_pr_ingestion_enabled: true)
    repo.update!(archived_at: Time.current)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollExternalOpenPrsJob)
  end

  it "no-ops when polling is paused" do
    Factories.repository(external_pr_ingestion_enabled: true)
    allow(AppSetting).to receive(:polling_paused?).and_return(true)

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollExternalOpenPrsJob)
  end
end
