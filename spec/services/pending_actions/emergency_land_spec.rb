require "rails_helper"

RSpec.describe PendingActions::EmergencyLand do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat_session) { ChatSession.create!(user: owner, repository: repository, mode: "coding") }

  def enable_emergency_land!
    Feature.find_or_create_by!(slug: "emergency_land") { |f| f.category = "Labs"; f.name = "Emergency land" }
           .update!(enabled: true)
  end

  def pending_action(job, branch_name: job.branch_name)
    payload = { "chat_session_id" => chat_session.id, "job_id" => job.id }
    payload["branch_name"] = branch_name if branch_name
    chat_session.pending_actions.create!(
      action: "emergency_land",
      payload: payload,
      requested_by: "agent"
    )
  end

  before { enable_emergency_land! }

  it "updates the confirmed branch, invokes the lander, and stores the Job as the result" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/stale")
    action = pending_action(job, branch_name: "syrus/incident")
    result = instance_double(EmergencyLand::Lander::Result, refused?: false, failure?: false, job: job)
    allow(EmergencyLand::Lander).to receive(:land).and_return(result)

    action.confirm!(user: owner)

    expect(action.reload).to be_confirmed
    expect(action.result).to eq(job)
    expect(job.reload.branch_name).to eq("syrus/incident")
    expect(EmergencyLand::Lander).to have_received(:land).with(job: job, user: owner)
  end

  it "re-checks the feature flag at confirmation time" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")
    action = pending_action(job)
    Feature.find_by!(slug: "emergency_land").update!(enabled: false)
    allow(EmergencyLand::Lander).to receive(:land)

    expect { action.confirm!(user: owner) }.to raise_error(ArgumentError, /not enabled/)
    expect(EmergencyLand::Lander).not_to have_received(:land)
  end

  it "re-checks repository admin permission at confirmation time" do
    admin_member = Factories.user
    RepositoryMembership.create!(repository: repository, user: admin_member, role: "admin")
    chat_session.update!(user: admin_member)
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")
    action = pending_action(job)
    RepositoryMembership.where(repository: repository, user: admin_member).delete_all
    allow(EmergencyLand::Lander).to receive(:land)

    expect { action.confirm!(user: admin_member) }.to raise_error(ArgumentError, /admin permissions/)
    expect(EmergencyLand::Lander).not_to have_received(:land)
  end

  it "refuses when the Job is no longer in coding state at confirmation time" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")
    action = pending_action(job)
    job.update!(state: "implemented")

    expect { action.confirm!(user: owner) }.to raise_error(ArgumentError, /not in coding state/)
  end

  it "rejects invalid branch_name payloads before confirmation" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")

    expect { pending_action(job, branch_name: "bad branch") }
      .to raise_error(ActiveRecord::RecordInvalid, /branch_name is not a valid branch name/)
  end

  it "raises the lander's refusal instead of confirming the action" do
    job = Factories.job_record(user: owner, repository: repository, state: "coding",
                               linked_chat_id: chat_session.id, branch_name: "syrus/incident")
    action = pending_action(job)
    result = instance_double(EmergencyLand::Lander::Result, refused?: true, failure?: false, message: "GitHub reports PR #5 is not mergeable.")
    allow(EmergencyLand::Lander).to receive(:land).and_return(result)

    expect { action.confirm!(user: owner) }.to raise_error(ArgumentError, /not mergeable/)
    expect(action.reload).to be_failed
  end
end
