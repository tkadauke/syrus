require "rails_helper"

RSpec.describe PendingActions::CancelJob do
  # The first user becomes the instance admin; keep the actors below ordinary.
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:job) { Factories.job(repository: repository, user: owner) }

  def cancel_request(by:)
    ChatSession.create!(user: by, repository: repository).pending_actions.create!(
      action: "cancel_job", requested_by: "agent", payload: { "job_id" => job.id }
    )
  end

  it "lets the owner cancel their own Job" do
    action = cancel_request(by: owner)

    expect(action.confirm!(user: owner)).to be(true)
    expect(job.reload).to be_closed
  end

  it "lets an admin cancel another user's Job instance-wide" do
    admin = Factories.user(admin: true)
    run = job.current_run
    action = cancel_request(by: admin)

    expect(action.confirm!(user: admin)).to be(true)
    expect(job.reload).to have_attributes(state: "closed", closure_reason: "cancelled")
    expect(run.reload).to be_cancelled
  end

  it "refuses a non-admin who does not own the Job" do
    other = Factories.user
    repository.repository_memberships.create!(user: other, role: "write")
    action = cancel_request(by: other)

    action.confirm!(user: other) rescue nil

    expect(action.reload).not_to be_confirmed
    expect(job.reload).not_to be_closed
  end
end
