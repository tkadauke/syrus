require "rails_helper"

RSpec.describe PendingActions::WorkflowOutcomeOverride do
  let!(:admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user:) }
  let(:job) { Factories.job(user:, repository:) }
  let(:chat_session) { ChatSession.create!(user:, repository:) }

  def pending_action
    chat_session.pending_actions.create!(
      action: "workflow_outcome_override", requested_by: "agent", reason: "Known false positive",
      payload: {
        "job_id" => job.id, "fingerprint_digest" => "f" * 64,
        "gate_kind" => "implementation_grader", "gate_identity" => "//:grade/rspec",
        "candidate_head_sha" => "a" * 40, "evidence_digest" => "e" * 64,
        "consequence" => "The failure remains visible.",
        "permission_role" => AgentRole::CHAT_PLANNER,
        "subject_selector_type" => "interactive_chat"
      }
    )
  end

  it "lets a permission-authorized non-admin confirm without optional guidance fields" do
    action = pending_action
    decision = instance_double(Permissions::PolicyEvaluator::Decision, deny?: false,
      to_h: { policy: :ask })
    override = instance_double(WorkflowOutcomeOverride, id: 123, step: nil)
    allow(WorkflowOutcomeOverrides::Authority).to receive(:call).and_return(decision)
    allow(WorkflowOutcomeOverrides::Recorder).to receive(:call).and_return(override)
    allow(WorkflowOutcomeOverrides::Resumer).to receive(:call)

    expect(action.confirm!(user:)).to be(true)
    expect(WorkflowOutcomeOverrides::Authority).to have_received(:call).with(hash_including(
      role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat",
      subject_selector_id: nil
    ))
    expect(WorkflowOutcomeOverrides::Recorder).to have_received(:call).with(hash_including(
      actor: user,
      permission_decision: hash_including(
        "operation" => "syrus.workflow_outcome_overrides/execute@v1"
      )
    ))
    expect(WorkflowOutcomeOverrides::Resumer).to have_received(:call).with(override:)
  end

  it "rejects an agent selector without its exact identity" do
    action = pending_action
    action.payload = action.payload.merge(
      "subject_selector_type" => "agent", "subject_selector_id" => nil
    )

    expect(action).not_to be_valid
    expect(action.errors[:payload]).to include("subject_selector_id is required for an agent")
  end
end
