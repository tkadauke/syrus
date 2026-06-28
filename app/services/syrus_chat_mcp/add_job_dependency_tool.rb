require "mcp"

module SyrusChatMcp
  class AddJobDependencyTool < MCP::Tool
    tool_name "add_job_dependency"

    description "Add a Job dependency so that one Job must land before another."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        depends_on_job_id: { type: "integer", description: "Syrus Job id that must land first." }
      },
      required: %w[job_id depends_on_job_id]
    )

    class << self
      def call(job_id:, depends_on_job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        user = chat_session.user

        job = user.jobs.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found: #{job_id}") unless job

        depends_on_job = user.jobs.find_by(id: depends_on_job_id)
        return SyrusChatMcp.invalid("job not found: #{depends_on_job_id}") unless depends_on_job

        JobDependency.find_or_create_by!(
          job: job,
          depends_on_job: depends_on_job
        ) do |dependency|
          dependency.source = "manual"
          dependency.created_by_user = user
        end

        SyrusChatMcp.success(
          job_id: job.id,
          depends_on_job_ids: depends_on_job_ids(job.reload)
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def depends_on_job_ids(job)
        job.dependencies.resolved.order(:depends_on_job_id).pluck(:depends_on_job_id)
      end
    end
  end
end
