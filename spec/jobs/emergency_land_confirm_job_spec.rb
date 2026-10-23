require "rails_helper"

RSpec.describe EmergencyLandConfirmJob do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository: repository, mode: "coding") }

  before do
    allow(Feature).to receive(:emergency_land_enabled?).and_return(true)
    allow(ChatTurnJob).to receive(:perform_later)
  end

  it "captures a direct checkout, creates its audit Job, and lands without a Workflow" do
    action = chat.pending_actions.create!(action: "emergency_land", requested_by: "agent", payload: {
      "repository_id" => repository.id, "branch_name" => "incident-fix", "title" => "Restore service", "description" => "Fix the incident"
    })
    action.start_confirmation!(user: owner, status: "queued", step: "Waiting")
    allow(CodingHandoffCapture).to receive(:capture!).and_return("handoff_branch" => "syrus/chat-#{chat.id}-emergency-#{action.id}", "head_sha" => "a" * 40)
    allow(EmergencyLand::Lander).to receive(:land) do |job:, **|
      job.update!(emergency_land_source_sha: "a" * 40)
      EmergencyLand::Lander::Result.new(status: :success, message: "merged", job: job, pr_number: 12)
    end

    expect { described_class.perform_now(action.id) }.to change(Job, :count).by(1).and change(Workflow, :count).by(0)
    job = Job.order(:id).last
    expect(job).to have_attributes(state: "implemented", branch_name: "syrus/chat-#{chat.id}-emergency-#{action.id}")
    expect(CodingHandoffCapture).to have_received(:capture!).with(hash_including(source_branch: "incident-fix"))
    expect(action.reload).to be_confirmed
  end

  it "lands an existing implemented branch-backed Job without Coding Mode takeover" do
    job = Factories.job_record(user: owner, repository: repository, state: "implemented", branch_name: "syrus/existing")
    action = chat.pending_actions.create!(action: "emergency_land", requested_by: "agent", payload: {
      "job_id" => job.id, "repository_id" => repository.id, "branch_name" => job.branch_name
    })
    action.start_confirmation!(user: owner, status: "queued", step: "Waiting")
    result = EmergencyLand::Lander::Result.new(status: :success, message: "merged", job: job, pr_number: 8)
    allow(EmergencyLand::Lander).to receive(:land).and_return(result)

    expect { described_class.perform_now(action.id) }.not_to change(Workflow, :count)
    expect(EmergencyLand::Lander).to have_received(:land).with(job: job, user: owner)
    expect(job.reload).to be_implemented
    expect(action.reload).to be_confirmed
  end


  it "durably fails the confirmation when checkout capture is refused" do
    action = chat.pending_actions.create!(action: "emergency_land", requested_by: "agent", payload: {
      "repository_id" => repository.id, "branch_name" => "incident-fix", "title" => "Restore service", "description" => "Fix the incident"
    })
    action.start_confirmation!(user: owner, status: "queued", step: "Waiting")
    allow(CodingHandoffCapture).to receive(:capture!).and_raise(CodingHandoffCapture::CaptureError, "coding checkout has uncommitted changes")

    described_class.perform_now(action.id)

    expect(action.reload).to be_failed
    expect(action.execution_error).to include("uncommitted changes")
    expect(action.execution_finished_at).to be_present
  end
end
