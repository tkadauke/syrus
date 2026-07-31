require "mcp"

module Mcp::Tools
  class AddJobDependencyTool < MCP::Tool
    tool_name "add_job_dependency"

    description "Add a Job dependency so that one Job must land before another. " \
                "Supply exactly one of depends_on_job_id (a prerequisite Job) or " \
                "depends_on_epic_id (a prerequisite Epic)."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        depends_on_job_id: { type: "integer", description: "Syrus Job id that must land first." },
        depends_on_epic_id: { type: "integer", description: "Syrus Epic id that must complete first." }
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
          add_job_target(job, depends_on_job_id, user)
        else
          add_epic_target(job, depends_on_epic_id, user)
        end
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def add_job_target(job, depends_on_job_id, user)
        depends_on_job = user.jobs.find_by(id: depends_on_job_id)
        return Mcp::Tools.invalid("job not found: #{depends_on_job_id}") unless depends_on_job

        JobDependency.find_or_create_by!(
          job: job,
          depends_on_job: depends_on_job
        ) do |dependency|
          dependency.source = "manual"
          dependency.created_by_user = user
        end

        success_payload(job.reload)
      end

      def add_epic_target(job, depends_on_epic_id, user)
        epic = user.epics.find_by(id: depends_on_epic_id)
        return Mcp::Tools.invalid("epic not found: #{depends_on_epic_id}") unless epic

        JobDependency.find_or_create_by!(
          job: job,
          depends_on_epic: epic
        ) do |dependency|
          dependency.source = "manual"
          dependency.created_by_user = user
        end

        success_payload(job.reload)
      end

      def success_payload(job)
        Mcp::Tools.success(
          job_id: job.id,
          depends_on_job_ids: depends_on_job_ids(job),
          depends_on_epic_ids: depends_on_epic_ids(job)
        )
      end

      def depends_on_job_ids(job)
        job.dependencies.where.not(depends_on_job_id: nil).order(:depends_on_job_id).pluck(:depends_on_job_id)
      end

      def depends_on_epic_ids(job)
        job.dependencies.where.not(depends_on_epic_id: nil).order(:depends_on_epic_id).pluck(:depends_on_epic_id)
      end
    end
  end
end
