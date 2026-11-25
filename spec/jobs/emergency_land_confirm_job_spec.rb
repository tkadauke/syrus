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
      EmergencyLand::Lander::Result.new(status: :success, message: "merged", job: job, pr_number: 12)
    end

    expect { described_class.perform_now(action.id) }.to change(Job, :count).by(1).and change(Workflow, :count).by(0)
    job = Job.order(:id).last
    expect(job).to have_attributes(
      state: "implemented", branch_name: "syrus/chat-#{chat.id}-emergency-#{action.id}", emergency_land_source_sha: "a" * 40
    )
    expect(CodingHandoffCapture).to have_received(:capture!).with(hash_including(source_branch: "incident-fix"))
    expect(action.reload).to be_confirmed
  end

  it "fails a newly captured Job durably when PR opening fails" do
    action = direct_action
    handoff_branch = "syrus/chat-#{chat.id}-emergency-#{action.id}"
    allow(CodingHandoffCapture).to receive(:capture!).and_return("handoff_branch" => handoff_branch, "head_sha" => "b" * 40)
    allow(EmergencyLand::Lander).to receive(:land) do |job:, **|
      EmergencyLand::Lander::Result.new(status: :failure, message: "GitHub error: Octokit::ServerError", job: job, pr_number: nil)
    end

    expect { described_class.perform_now(action.id) }.to change(Job, :count).by(1)

    job = Job.order(:id).last
    expect(job).to have_attributes(state: "failed", branch_name: handoff_branch, emergency_land_source_sha: "b" * 40)
    expect(job.may_approve?).to be(false)
    awaiting_approval = Filters::Chips::Jobs::Attention.new(scope: Job.all, op: :is, value: "awaiting_approval").apply
    expect(awaiting_approval).not_to include(job)
    expect(action.reload).to be_failed
  end

  it "preserves a recorded PR when landing fails after opening it" do
    action = direct_action
    allow(CodingHandoffCapture).to receive(:capture!).and_return(
      "handoff_branch" => "syrus/chat-#{chat.id}-emergency-#{action.id}", "head_sha" => "c" * 40
    )
    allow(EmergencyLand::Lander).to receive(:land) do |job:, **|
      job.update!(pr_number: 73)
      EmergencyLand::Lander::Result.new(status: :failure, message: "GitHub error after opening PR", job: job, pr_number: nil)
    end

    described_class.perform_now(action.id)

    expect(Job.order(:id).last).to have_attributes(state: "failed", pr_number: 73)
  end

  it "retries a captured Job without recapturing it or creating another Job" do
    captured = Factories.job_record(
      user: owner, repository: repository, kind: "direct", state: "failed",
      issue_number: nil, branch_name: "syrus/chat-capture", pr_number: 73, emergency_land_source_sha: "d" * 40
    )
    action = existing_action(captured)
    allow(CodingHandoffCapture).to receive(:capture!)
    allow(EmergencyLand::Lander).to receive(:land) do |job:, **|
      job.update!(state: "closed", closure_reason: "emergency_landed")
      EmergencyLand::Lander::Result.new(status: :success, message: "merged", job: job, pr_number: 73)
    end

    expect { described_class.perform_now(action.id) }.not_to change(Job, :count)

    expect(CodingHandoffCapture).not_to have_received(:capture!)
    expect(EmergencyLand::Lander).to have_received(:land).with(job: captured, user: owner)
    expect(captured.reload).to have_attributes(state: "closed", pr_number: 73, branch_name: "syrus/chat-capture")
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

    expect { described_class.perform_now(action.id) }.not_to change(Job, :count)

    expect(action.reload).to be_failed
    expect(action.execution_error).to include("uncommitted changes")
    expect(action.execution_finished_at).to be_present
  end

  it "does not change an existing Job's lifecycle when landing fails" do
    existing = Factories.job_record(user: owner, repository: repository, state: "implemented", branch_name: "syrus/existing")
    action = existing_action(existing)
    allow(EmergencyLand::Lander).to receive(:land).and_return(
      EmergencyLand::Lander::Result.new(status: :failure, message: "GitHub unavailable", job: existing, pr_number: nil)
    )

    described_class.perform_now(action.id)

    expect(existing.reload).to be_implemented
    expect(action.reload).to be_failed
  end

  def direct_action
    action = chat.pending_actions.create!(action: "emergency_land", requested_by: "agent", payload: {
      "repository_id" => repository.id, "branch_name" => "incident-fix", "title" => "Restore service", "description" => "Fix the incident"
    })
    action.start_confirmation!(user: owner, status: "queued", step: "Waiting")
    action
  end

  def existing_action(job)
    action = chat.pending_actions.create!(action: "emergency_land", requested_by: "agent", payload: {
      "job_id" => job.id, "repository_id" => repository.id, "branch_name" => job.branch_name
    })
    action.start_confirmation!(user: owner, status: "queued", step: "Waiting")
    action
  end
end
