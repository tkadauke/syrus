require "rails_helper"

RSpec.describe PendingActions::ForceFailJob do
  it "force-fails the job and clears the admin stuck snapshot" do
    admin = Factories.user(admin: true)
    repository = Factories.repository(user: admin)
    chat_session = ChatSession.create!(user: admin, repository: repository)
    job = Factories.job(user: admin, repository: repository, state: "running")
    action = chat_session.pending_actions.create!(
      action: "force_fail_job",
      payload: { "job_id" => job.id },
      reason: "Operator determined the job is stuck.",
      requested_by: "agent"
    )
    allow(Admin::StuckItemsCache).to receive(:clear!).and_call_original

    expect(action.confirm!(user: admin)).to be true

    expect(job.reload).to be_failed
    expect(Admin::StuckItemsCache).to have_received(:clear!)
  end

  it "does not clear the admin stuck snapshot when the job cannot be force-failed" do
    admin = Factories.user(admin: true)
    repository = Factories.repository(user: admin)
    chat_session = ChatSession.create!(user: admin, repository: repository)
    job = Factories.job(user: admin, repository: repository, state: "failed")
    action = chat_session.pending_actions.create!(
      action: "force_fail_job",
      payload: { "job_id" => job.id },
      reason: "Operator determined the job is stuck.",
      requested_by: "agent"
    )
    allow(Admin::StuckItemsCache).to receive(:clear!).and_call_original

    expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /cannot be force-failed/)

    expect(Admin::StuckItemsCache).not_to have_received(:clear!)
  end
end
