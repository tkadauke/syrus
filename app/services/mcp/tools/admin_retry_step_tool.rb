require "mcp"

module Mcp::Tools
  class AdminRetryStepTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "admin_retry_step"
    description <<~DESC
      Request retrying a failed Step on one or more Workflows. Pass
      workflow_id for a single Workflow (unchanged single-confirmation
      behavior) or workflow_ids for multiple Workflows retrying the same
      step_slug, which requires a shared reason (the root cause behind
      retrying every Workflow in the batch) and creates one grouped pending
      action the operator confirms or rejects together. Requires operator
      confirmation.
    DESC

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Workflow id that owns the failed Step." },
        workflow_ids: {
          type: "array",
          items: { type: "integer" },
          description: "Multiple Workflow ids retrying the same step_slug as one grouped pending action, sharing one reason."
        },
        step_slug: { type: "string", description: "Step kind to retry, for example implement or graders." },
        reason: { type: "string", description: "Operator-facing reason for retrying this failed Step." }
      },
      required: %w[step_slug reason]
    )

    class << self
      def call(workflow_id: nil, workflow_ids: nil, step_slug:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        step_slug = step_slug.to_s.strip
        return Mcp::Tools.invalid("step_slug is required") if step_slug.empty?
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        ids, bulk, error = resolve_ids(id: workflow_id, ids: workflow_ids, param_name: "workflow_id")
        return error if error

        workflows = ids.map { |id| Workflow.find_by(id: id) }
        missing = ids.zip(workflows).select { |_id, workflow| workflow.nil? }.map(&:first)
        return Mcp::Tools.invalid("workflow not found: #{missing.join(', ')}") if missing.any?
        not_retryable = workflows.reject { |workflow| workflow.steps.exists?(kind: step_slug) }
        return Mcp::Tools.invalid("step '#{step_slug}' not found on #{not_retryable.map(&:slug).join(', ')}") if not_retryable.any?

        unless bulk
          workflow = workflows.first
          return create_pending_admin_action(
            server_context: server_context,
            chat_session: chat_session,
            action: "admin_retry_step",
            payload: { "workflow_id" => workflow.id, "step_slug" => step_slug },
            reason: reason,
            message: "Retry step '#{step_slug}' on #{workflow.slug}?"
          )
        end

        group = create_pending_action_group!(
          server_context: server_context,
          chat_session: chat_session,
          member_attributes: workflows.map { |workflow|
            { action: "admin_retry_step", payload: { "workflow_id" => workflow.id, "step_slug" => step_slug }, requested_by: "agent", reason: reason }
          },
          reason: reason
        )
        bulk_action_response(group: group, message: "Retry step '#{step_slug}' on #{workflows.size} Workflows?")
      end
    end
  end
end
