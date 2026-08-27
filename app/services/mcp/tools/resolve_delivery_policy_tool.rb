require "mcp"

module Mcp::Tools
  class ResolveDeliveryPolicyTool < MCP::Tool
    extend RefMovementToolSupport

    tool_name "resolve_delivery_policy"

    description "Explain what delivery policy applies to this repository (or one of its Jobs): " \
                "selected track, landing branch, grade phases, approval requirements, and which " \
                "promotion/hotfix-sync/upstream-export/ref-movement actions are enabled."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Optional Syrus Job id to resolve track-specific answers for." }
      }
    )

    class << self
      def call(server_context:, job_id: nil)
        context = McpToolContext.from_server_context(server_context)
        repository = context.repository
        return Mcp::Tools.invalid("no repository attached") unless repository

        job = nil
        if job_id.present?
          job, error = find_context_job(context, job_id)
          return error if error
          return Mcp::Tools.invalid("job belongs to a different repository") unless job.repository_id == repository.id
        end

        policy = DeliveryPolicy.for(repository: repository, job: job)

        Mcp::Tools.success(
          repository: repository.slug,
          job_id: job&.id,
          delivery_track: policy.job_delivery_track(job),
          job_landing_branch: policy.job_landing_branch(job),
          review_grade_phase: policy.review_grade_phase(job),
          landing_grade_phase: policy.landing_grade_phase(job),
          approval: {
            configured: policy.approval_configured?,
            job_approval_satisfied: job ? policy.job_approval_satisfied?(job) : nil,
            requires_operator_approval_for_promotion: policy.requires_operator_approval_for_promotion?
          },
          promotion: { enabled: policy.promotion_enabled?, mode: policy.promotion_mode },
          hotfix_sync: { enabled: policy.hotfix_sync_enabled?, mode: policy.hotfix_sync_mode },
          upstream_export: {
            enabled: policy.upstream_export_enabled?,
            mode: policy.upstream_export_mode(job),
            after_local_approval: policy.export_upstream_after_local_approval?(job)
          },
          ref_movement_actions: policy.ref_movement_actions.transform_values do |action|
            { enabled: action.enabled, mode: action.mode, grade_phases: action.grade_phases }
          end
        )
      end
    end
  end
end
