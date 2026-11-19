require "mcp"

module Mcp::Tools
  class ReplaceJobDependencyTool < MCP::Tool
    tool_name "replace_job_dependency"

    description "Atomically replace one prerequisite Job with another. The replacement uses the removed edge's satisfaction mode unless one is supplied."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        remove_dependency_job_id: { type: "integer", description: "Current prerequisite Job id to remove." },
        add_dependency_job_id: { type: "integer", description: "Replacement prerequisite Job id to add." },
        satisfaction_mode: { type: "string", enum: JobDependency::SATISFACTION_MODES },
        required_deployment_stage_name: { type: "string" }
      },
      required: %w[job_id remove_dependency_job_id add_dependency_job_id]
    )

    class << self
      def call(job_id:, remove_dependency_job_id:, add_dependency_job_id:, satisfaction_mode: nil,
        required_deployment_stage_name: nil, server_context:)
        user = server_context.fetch(:chat_session).user
        scope = job_scope_for(user)
        job = scope.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job
        removed_job = scope.find_by(id: remove_dependency_job_id)
        return Mcp::Tools.invalid("job not found: #{remove_dependency_job_id}") unless removed_job
        added_job = scope.find_by(id: add_dependency_job_id)
        return Mcp::Tools.invalid("job not found: #{add_dependency_job_id}") unless added_job
        return Mcp::Tools.invalid("replacement dependency must be in the same repository") unless added_job.repository_id == job.repository_id

        ApplicationRecord.transaction do
          job.lock!
          removed = job.dependencies.lock.find_by(depends_on_job: removed_job)
          raise ArgumentError, "Job dependency does not exist: #{remove_dependency_job_id}" unless removed

          mode = satisfaction_mode.presence || removed.satisfaction_mode
          stage = satisfaction_mode.present? ? required_deployment_stage_name : (required_deployment_stage_name.presence || removed.required_deployment_stage_name)
          replacement = JobDependency.new(job:, depends_on_job: added_job, source: "manual",
            created_by_user: user, satisfaction_mode: mode, required_deployment_stage_name: stage)
          replacement.validate!
          removed.destroy!
          replacement.save!
        end

        Mcp::Tools::AddJobDependencyTool.send(:success_payload, job.reload)
      rescue ArgumentError => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def job_scope_for(user)
        user.admin? ? Job.visible_to(user, scope: Job.all) : Job.visible_to(user)
      end
    end
  end
end
