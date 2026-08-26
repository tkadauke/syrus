require "mcp"

module Mcp::Tools
  class ReadRefMovementStatusTool < MCP::Tool
    extend RefMovementToolSupport

    tool_name "read_ref_movement_status"

    description "Inspect one dispatched ref-movement action's current status: source/target refs, " \
                "the Workflow's current state, and any PR link it opened."

    input_schema(
      properties: {
        ref_movement_action_id: { type: "integer", description: "RefMovementAction id returned by dispatch_ref_movement_action." }
      },
      required: %w[ref_movement_action_id]
    )

    class << self
      def call(ref_movement_action_id:, server_context:)
        context = McpToolContext.from_server_context(server_context)
        record, error = find_context_ref_movement_action(context, ref_movement_action_id)
        return error if error

        job = record.job
        workflow = record.workflow

        Mcp::Tools.success(
          ref_movement_action_id: record.id,
          action_name: record.action_name,
          state: record.state,
          blocked_reason: record.blocked_reason,
          requested_by: record.requested_by_user.email_address,
          source_kind: record.source_kind,
          source_ref: record.source_ref,
          target_kind: record.target_kind,
          target_ref: record.target_ref,
          target_repository: record.target_repository&.slug,
          target_inferred: record.target_inferred,
          mode: record.mode,
          grade_phases: record.grade_phases,
          job: job && { id: job.id, slug: job.slug, state: job.state },
          workflow: workflow && { id: workflow.id, state: workflow.state, trigger_kind: workflow.trigger_kind },
          pr_link: pr_link_payload(job)
        )
      end

      private

      def pr_link_payload(job)
        return nil unless job

        link = job.pr_links.find_by(role: JobPrLink::ROLE_UPSTREAM_EXPORT)
        return nil unless link

        {
          pr_number: link.pr_number,
          pr_state: link.metadata.to_h["pr_state"],
          source_ref: link.source_ref,
          target_repository: Repository.find_by(id: link.target_repository_id)&.slug,
          target_ref: link.target_ref
        }
      end
    end
  end
end
