require "rails_helper"

RSpec.describe Mcp::Tools::RequestWorkflowOutcomeOverrideTool do
  it "persists the exact coworker selector identity for execution authorization" do
    job = instance_double(Job, id: 12)
    fingerprint = instance_double(WorkflowOutcomeOverrides::Fingerprint, digest: "f" * 64)
    candidate = instance_double(WorkflowOutcomeOverrides::Candidate,
      fingerprint:, gate_failure: {
        gate_kind: "review", gate_identity: "security:panel:coworker",
        candidate_head_sha: "a" * 40, evidence_digest: "e" * 64
      }, consequence: "The evidence remains visible.")
    resolver = instance_double(WorkflowOutcomeOverrides::CandidateResolver, find!: candidate)
    agent = double("Coworker", id: 77)
    context = instance_double(McpToolContext, role: AgentRole::COWORKER_CHAT, agent_actor: agent, run?: false)
    pending = instance_double(ChatPendingAction, id: 5, state: "pending")
    server_context = { chat_session: instance_double(ChatSession) }
    allow(described_class).to receive(:find_job!).and_return(job)
    allow(WorkflowOutcomeOverrides::CandidateResolver).to receive(:new).and_return(resolver)
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    allow(described_class).to receive(:create_pending_action_for_current_message!).and_return(pending)

    implementation = described_class.method(:call)
    implementation = implementation.super_method until implementation.owner == described_class.singleton_class
    implementation.call(job_id: 12, fingerprint_digest: "f" * 64,
      reason: "Known false positive", server_context:)

    expect(described_class).to have_received(:create_pending_action_for_current_message!).with(
      server_context, server_context.fetch(:chat_session), hash_including(
        payload: hash_including(
          "permission_role" => AgentRole::COWORKER_CHAT,
          "subject_selector_type" => "agent", "subject_selector_id" => "77"
        )
      )
    )
  end
end
