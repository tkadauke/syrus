require "rails_helper"

RSpec.describe PollAllMainBranchHealthJob do
  it "enqueues PollMainBranchHealthJob for each active repository" do
    r1 = Factories.repository
    r2 = Factories.repository
    archived = Factories.repository
    archived.archive!

    expect {
      described_class.perform_now
    }.to have_enqueued_job(PollMainBranchHealthJob).exactly(2).times
      .and have_enqueued_job(PollMainBranchHealthJob).with(r1.id)
      .and have_enqueued_job(PollMainBranchHealthJob).with(r2.id)
  end

  it "does nothing when polling is globally paused" do
    allow(AppSetting).to receive(:polling_paused?).and_return(true)
    Factories.repository

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMainBranchHealthJob)
  end
end
