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

  it "does nothing when polling is globally paused" do
    allow(AppSetting).to receive(:polling_paused?).and_return(true)
    Factories.repository

    expect {
      described_class.perform_now
    }.not_to have_enqueued_job(PollMainBranchHealthJob)
  end

  it "can enqueue a broad target sweep for every active health-checked repository" do
    r1 = Factories.repository
    r2 = Factories.repository
    Factories.repository(main_branch_health_enabled: false)

    expect {
      described_class.perform_now(target_selection_mode: "broad")
    }.to have_enqueued_job(PollMainBranchHealthJob).exactly(2).times
      .and have_enqueued_job(PollMainBranchHealthJob).with(r1.id, target_selection_mode: "broad")
      .and have_enqueued_job(PollMainBranchHealthJob).with(r2.id, target_selection_mode: "broad")
  end

  it "accepts the recurring-task argument hash for broad target sweeps" do
    repository = Factories.repository

    expect {
      described_class.perform_now({ "target_selection_mode" => "broad" })
    }.to have_enqueued_job(PollMainBranchHealthJob).with(repository.id, target_selection_mode: "broad")
  end
end
