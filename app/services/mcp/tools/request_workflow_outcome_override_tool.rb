require "mcp"

module Mcp::Tools
  class RequestWorkflowOutcomeOverrideTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "request_workflow_outcome_override"
    description <<~DESC
      Request operator confirmation for an exact-evidence workflow outcome override.
      Use inspect_workflow_outcome_overrides first. Diagnose and try to repair the
      underlying failure before requesting an override. If the failure appears to
      be a Syrus defect or false-positive grader, report or link that defect when
      possible. The diagnosis, remediation attempted, and justification are audit
      evidence, not a substitute for the exact revision/evidence fingerprint.
    DESC
    input_schema(
      properties: {
        job_id: { type: "integer" },
        fingerprint_digest: { type: "string", description: "Exact candidate fingerprint returned by inspection." },
        diagnosis: { type: "string", description: "What caused the failure." },
        remediation_attempted: { type: "string", description: "What was tried to fix the cause." },
        reason: { type: "string", description: "Why overriding the remaining failure is justified." },
        bug_report_url: { type: "string", description: "Optional linked Syrus bug report." }
      },
      required: %w[job_id fingerprint_digest reason]
    )

    class << self
      include JobLifecycleToolSupport
      include ProposalToolSupport

      def call(job_id:, fingerprint_digest:, reason:, diagnosis: nil, remediation_attempted: nil, bug_report_url: nil, server_context:)
        job = find_job!(job_id)
        candidate = WorkflowOutcomeOverrides::CandidateResolver.new(job).find!(fingerprint_digest)
        tool_context = McpToolContext.from_server_context(server_context)
        action = create_pending_action_for_current_message!(
          server_context, server_context.fetch(:chat_session), action: "workflow_outcome_override",
          requested_by: "agent", reason: reason.to_s.strip,
          payload: {
            "job_id" => job.id, "fingerprint_digest" => candidate.fingerprint.digest,
            "gate_kind" => candidate.gate_failure[:gate_kind], "gate_identity" => candidate.gate_failure[:gate_identity],
            "candidate_head_sha" => candidate.gate_failure[:candidate_head_sha], "evidence_digest" => candidate.gate_failure[:evidence_digest],
            "diagnosis" => diagnosis.to_s.strip, "remediation_attempted" => remediation_attempted.to_s.strip,
            "bug_report_url" => bug_report_url.to_s.strip.presence, "consequence" => candidate.consequence,
            "permission_role" => tool_context.role,
            "subject_selector_type" => tool_context.agent_actor ? "agent" : "interactive_chat",
            "subject_selector_id" => tool_context.agent_actor&.id&.to_s
          }.compact
        )
        Mcp::Tools.success(pending_action_id: action.id, state: action.state,
          message: I18n.t("server.mcp.workflow_outcome_overrides.pending_confirmation",
            evidence: candidate.fingerprint.digest.first(12)))
      rescue WorkflowOutcomeOverrides::CandidateResolver::NotFound => error
        Mcp::Tools.invalid(error.message)
      end
    end
  end
end
