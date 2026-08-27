require "mcp"

module Mcp::Tools
  class DispatchRefMovementActionTool < MCP::Tool
    extend RefMovementToolSupport

    tool_name "dispatch_ref_movement_action"

    description "Dispatch a configured delivery.ref_movement_actions entry. " \
                "send_job_upstream requires job_id (exports that Job's own branch upstream). " \
                "submit_branch_upstream optionally takes source_branch (defaults to the repository's " \
                "development track branch) and target_branch (defaults to the canonical repository's " \
                "resolved development track branch). Always creates a durable RefMovementAction audit " \
                "record, whether or not the dispatch actually launches a Workflow — check the returned " \
                "state and blocked_reason."

    input_schema(
      properties: {
        action: { type: "string", enum: %w[send_job_upstream submit_branch_upstream], description: "Ref-movement action name." },
        job_id: { type: "integer", description: "Required for send_job_upstream: the Job whose branch to export." },
        source_branch: { type: "string", description: "submit_branch_upstream only: branch to export. Defaults to the development track branch." },
        target_branch: { type: "string", description: "submit_branch_upstream only: explicit target branch override on the canonical repository." }
      },
      required: %w[action]
    )

    class << self
      def call(action:, server_context:, job_id: nil, source_branch: nil, target_branch: nil)
        context = McpToolContext.from_server_context(server_context)
        repository = context.repository
        return Mcp::Tools.invalid("no repository attached") unless repository

        source =
          case action
          when "send_job_upstream"
            return Mcp::Tools.invalid("job_id is required for send_job_upstream") if job_id.blank?

            job, error = find_context_job(context, job_id)
            return error if error
            return Mcp::Tools.invalid("job belongs to a different repository") unless job.repository_id == repository.id

            job
          when "submit_branch_upstream"
            source_branch.to_s.strip.presence
          end

        ref_movement_action = RefMovementAction.dispatch!(
          repository: repository,
          actor: context.user,
          action: action,
          source: source,
          target: target_branch.to_s.strip.presence
        )

        Mcp::Tools.success(ref_movement_action_payload(ref_movement_action))
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end

      private

      def ref_movement_action_payload(record)
        {
          ref_movement_action_id: record.id,
          action_name: record.action_name,
          state: record.state,
          blocked_reason: record.blocked_reason,
          source_kind: record.source_kind,
          source_ref: record.source_ref,
          target_kind: record.target_kind,
          target_ref: record.target_ref,
          target_repository: record.target_repository&.slug,
          target_inferred: record.target_inferred,
          mode: record.mode,
          grade_phases: record.grade_phases,
          job_id: record.job_id,
          workflow_id: record.workflow_id
        }
      end
    end
  end
end
