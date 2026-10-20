require "rails_helper"

RSpec.describe PendingActions::EmergencyLand do
  include ActiveJob::TestHelper
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat_session) { ChatSession.create!(user: owner, repository: repository, mode: "coding") }

  before do
    Feature.find_or_create_by!(slug: "emergency_land") { |feature| feature.category = "Labs"; feature.name = "Emergency land" }.update!(enabled: true)
  end

  it "queues confirmed landing on the chat worker" do
    job = Factories.job_record(user: owner, repository: repository, state: "implemented", branch_name: "syrus/incident")
    action = chat_session.pending_actions.create!(action: "emergency_land", payload: {
      "job_id" => job.id, "repository_id" => repository.id, "branch_name" => job.branch_name
    }, requested_by: "agent")

    expect { action.confirm!(user: owner) }.to have_enqueued_job(EmergencyLandConfirmJob).with(action.id)
    expect(action.reload).to be_confirming
    expect(action.execution_status).to eq("running")
  end

  it "requires repository context for a direct checkout submission" do
    expect {
      chat_session.pending_actions.create!(action: "emergency_land",
        payload: { "title" => "Incident fix", "description" => "Restore service" }, requested_by: "agent")
    }.to raise_error(ActiveRecord::RecordInvalid, /repository_id is required for direct submission/)
  end
end
