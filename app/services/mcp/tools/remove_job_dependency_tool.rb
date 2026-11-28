require "mcp"

module Mcp::Tools
  class RemoveJobDependencyTool < MCP::Tool
    tool_name "remove_job_dependency"

    description "Remove a Job dependency. Supply exactly one of depends_on_job_id " \
                "(a prerequisite Job) or depends_on_epic_id (a prerequisite Epic)."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        depends_on_job_id: { type: "integer", description: "Syrus Job id to remove as a dependency." },
        depends_on_epic_id: { type: "integer", description: "Syrus Epic id to remove as a dependency." },
        hold_running: { type: "boolean", description: "When the edit leaves the Job's active Run executing ahead of its dependencies, request a confirmed hold_job instead of rejecting the edit: on confirmation the edit is applied and the Job's active work is cancelled, returning it to waiting. Requires owning the Job (or an admin). Defaults to false: the edit is rejected, naming the active Run." },
        reason: { type: "string", description: "Audit reason for the hold requested with hold_running." }
      },
      required: %w[job_id]
    )

    class << self
      include DependencyEditHoldSupport

      def call(job_id:, depends_on_job_id: nil, depends_on_epic_id: nil, hold_running: false, reason: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        user = chat_session.user

        return Mcp::Tools.invalid("exactly one of depends_on_job_id or depends_on_epic_id must be supplied") if
          depends_on_job_id.nil? == depends_on_epic_id.nil?

        job = job_scope_for(user).find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        depends_on_job = nil
        if depends_on_job_id
          depends_on_job = job_scope_for(user).find_by(id: depends_on_job_id)
          return Mcp::Tools.invalid("job not found: #{depends_on_job_id}") unless depends_on_job
        end

        begin
          ApplicationRecord.transaction do
            if depends_on_job
              JobDependency.where(job: job, depends_on_job: depends_on_job).destroy_all
            else
              JobDependency.where(job: job, depends_on_epic_id: depends_on_epic_id).destroy_all
            end
            JobDependencyEditGuard.enforce!(job)
          end
        rescue JobDependencyEditGuard::ActiveRunRejection
          raise unless hold_running == true

          return request_hold_for_dependency_edit(server_context:, job:, tool_name: tool_name, reason:,
            arguments: { job_id: job.id, depends_on_job_id:, depends_on_epic_id: })
        end

        Mcp::Tools.success(
          job_id: job.id,
          depends_on_job_ids: depends_on_job_ids(job.reload),
          depends_on_epic_ids: depends_on_epic_ids(job)
        )
      rescue JobDependencyEditGuard::ActiveRunRejection => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def depends_on_job_ids(job)
        job.dependencies.where.not(depends_on_job_id: nil).order(:depends_on_job_id).pluck(:depends_on_job_id)
      end

      def depends_on_epic_ids(job)
        job.dependencies.where.not(depends_on_epic_id: nil).order(:depends_on_epic_id).pluck(:depends_on_epic_id)
      end

      def job_scope_for(user)
        user.admin? ? Job.visible_to(user, scope: Job.all) : Job.visible_to(user)
      end
    end
  end
end
