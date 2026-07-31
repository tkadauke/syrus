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
        depends_on_epic_id: { type: "integer", description: "Syrus Epic id to remove as a dependency." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, depends_on_job_id: nil, depends_on_epic_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        user = chat_session.user

        return Mcp::Tools.invalid("exactly one of depends_on_job_id or depends_on_epic_id must be supplied") if
          depends_on_job_id.nil? == depends_on_epic_id.nil?

        job = user.jobs.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        if depends_on_job_id
          depends_on_job = user.jobs.find_by(id: depends_on_job_id)
          return Mcp::Tools.invalid("job not found: #{depends_on_job_id}") unless depends_on_job

          JobDependency.where(job: job, depends_on_job: depends_on_job).destroy_all
        else
          JobDependency.where(job: job, depends_on_epic_id: depends_on_epic_id).destroy_all
        end

        Mcp::Tools.success(
          job_id: job.id,
          depends_on_job_ids: depends_on_job_ids(job.reload),
          depends_on_epic_ids: depends_on_epic_ids(job)
        )
      end

      private

      def depends_on_job_ids(job)
        job.dependencies.where.not(depends_on_job_id: nil).order(:depends_on_job_id).pluck(:depends_on_job_id)
      end

      def depends_on_epic_ids(job)
        job.dependencies.where.not(depends_on_epic_id: nil).order(:depends_on_epic_id).pluck(:depends_on_epic_id)
      end
    end
  end
end
