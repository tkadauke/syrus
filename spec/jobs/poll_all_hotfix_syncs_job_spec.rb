require "rails_helper"

RSpec.describe PollAllHotfixSyncsJob do
  it "enqueues one repository poll for active repositories with hotfix sync enabled" do
    configured = Factories.repository
    unconfigured = Factories.repository
    archived = Factories.repository
    archived.archive!

    allow(DeliveryPolicy).to receive(:for).with(repository: configured).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: true)
    )
    allow(DeliveryPolicy).to receive(:for).with(repository: unconfigured).and_return(
      instance_double(DeliveryPolicy, hotfix_sync_enabled?: false)
    )

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollHotfixSyncJob).once.with(configured.id)
  end

  it "does nothing when polling is globally paused" do
    allow(AppSetting).to receive(:polling_paused?).and_return(true)
    Factories.repository

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollHotfixSyncJob)
  end
end
