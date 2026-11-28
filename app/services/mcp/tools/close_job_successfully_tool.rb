require "mcp"

module Mcp::Tools
  class CloseJobSuccessfullyTool < MCP::Tool
    extend ProposalToolSupport
    extend BulkPendingActionToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "close_job_successfully"

    description <<~DESC
      Request that one or more Syrus Jobs be closed with a registered semantic
      reason. Agents must always supply a reason. Pass job_id for a single Job
      (normally retaining single-confirmation behavior) or job_ids for multiple Jobs, which
      creates one grouped pending action the operator confirms or rejects
      together -- every Job in the group is closed with the same
      closure_reason; use separate calls if different Jobs need different
      reasons. The Job(s) and any tracked PR are not changed until the
      operator confirms the pending action.
      A coworker with autonomous lifecycle permission may immediately close a
      Job it proposed when the reason permits autonomous agent use. Declined
      reasons always remain subject to operator confirmation.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to close successfully." },
        job_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Syrus Job ids to close successfully as one grouped pending action, all with the same closure_reason."
        },
        closure_reason: {
          type: "string",
          enum: Job::ClosureReason.agent_values,
          description: "Registered closure reason to record on the Job(s)."
        },
        references: {
          type: "array", items: { type: "object" },
          description: "Referenced Jobs, PRs, or Epics, each with type and id. Required by replacement and implemented_elsewhere reasons."
        },
        note: { type: "string", description: "Closure explanation. Required for wont_do and infeasible." },
        comment: {
          type: "string",
          description: "Optional explanatory comment to post on the PR before closing it."
        }
      },
      required: %w[closure_reason]
    )

    class << self
      def call(job_id: nil, job_ids: nil, closure_reason:, references: [], note: nil, comment: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        return Mcp::Tools.invalid("closure_reason is required") if closure_reason.blank?
        definition = Job::ClosureReason.by_reason[closure_reason.to_s]
        return Mcp::Tools.invalid("closure_reason is not registered") unless definition
        return Mcp::Tools.invalid("cancelled is reserved for a human close without a reason") if closure_reason.to_s == "cancelled"
        return Mcp::Tools.invalid("#{closure_reason} requires a Job, PR, or Epic reference") if definition.requires_reference && Array(references).empty?
        return Mcp::Tools.invalid("#{closure_reason} requires a note") if definition.requires_note && note.to_s.strip.blank?
        invalid_reference = Array(references).find do |reference|
          value = reference.to_h.stringify_keys
          !value["type"].to_s.in?(%w[Job PR Epic]) || value["id"].blank?
        end
        return Mcp::Tools.invalid("references require type Job, PR, or Epic and an id") if invalid_reference

        ids, bulk, error = resolve_ids(id: job_id, ids: job_ids, param_name: "job_id")
        return error if error

        jobs = ids.map { |id| find_job!(id) }
        jobs.each do |job|
          return Mcp::Tools.invalid("#{job.slug} is already closed. Reopen it before requesting another closure.") if job.closed?
          return Mcp::Tools.invalid("#{job.slug} cannot be closed from #{job.state}.") unless job.may_close?
        end

        unless bulk
          job = jobs.first
          payload = { "job_id" => job.id, "closure_reason" => closure_reason.to_s }
          payload["references"] = references if Array(references).any?
          payload["note"] = note.to_s if note.present?
          payload["comment"] = comment.to_s if comment.present?

          pending_action = create_pending_action_for_current_message!(
            server_context,
            chat_session,
            action: "close_job_successfully",
            payload: payload,
            requested_by: "agent",
            subject: McpToolContext.from_server_context(server_context).agent_actor
          )

          if autonomous_coworker_close?(server_context:, job:, definition:)
            pending_action.confirm!
            return Mcp::Tools.success(
              pending_action_id: pending_action.id,
              state: pending_action.reload.state,
              job_id: job.id,
              closure_reason: closure_reason.to_s,
              message: "#{job.slug} was closed under the coworker's autonomous lifecycle permission."
            )
          end

          return Mcp::Tools.success(
            pending_action_id: pending_action.id,
            state: pending_action.state,
            job_id: job.id,
            closure_reason: closure_reason.to_s,
            message: "Successful Job close requires operator confirmation."
          )
        end

        member_attributes = jobs.map do |job|
          member_payload = { "job_id" => job.id, "closure_reason" => closure_reason.to_s }
          member_payload["references"] = references if Array(references).any?
          member_payload["note"] = note.to_s if note.present?
          member_payload["comment"] = comment.to_s if comment.present?
          {
            action: "close_job_successfully", payload: member_payload, requested_by: "agent",
            subject: McpToolContext.from_server_context(server_context).agent_actor
          }
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: member_attributes
        )
        bulk_action_response(group: group, message: "Close #{jobs.size} Jobs as #{closure_reason}?")
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def autonomous_coworker_close?(server_context:, job:, definition:)
        context = McpToolContext.from_server_context(server_context)
        return false unless context.role.in?([ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ])
        return false unless definition.agent_allowed
        return false unless context.agent_actor && job.proposer == context.agent_actor

        server_context.dig(:coworker_permission_authorizations, tool_name) == true
      end
    end
  end
end
