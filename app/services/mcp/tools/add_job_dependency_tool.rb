require "mcp"

module Mcp::Tools
  class AddJobDependencyTool < MCP::Tool
    tool_name "add_job_dependency"

    description "Add a Job dependency so that one Job waits for another Job or Epic. " \
                "Supply exactly one of depends_on_job_id (a prerequisite Job) or " \
                "depends_on_epic_id (a prerequisite Epic). By default the target must " \
                "finish successfully; use satisfaction_mode='closed' only for cleanup " \
                "or teardown gates where any terminal close is acceptable. Use " \
                "satisfaction_mode='deployment_stage' with required_deployment_stage_name " \
                "to wait for a configured deployment stage on a prerequisite Job."

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to update." },
        depends_on_job_id: { type: "integer", description: "Syrus Job id that must satisfy the dependency first." },
        depends_on_epic_id: { type: "integer", description: "Syrus Epic id that must satisfy the dependency first." },
        satisfaction_mode: {
          type: "string",
          enum: JobDependency::SATISFACTION_MODES,
          description: "success waits for a successful close; closed waits for any terminal close; deployment_stage waits for a configured deployment stage. Defaults to success."
        },
        required_deployment_stage_name: { type: "string", description: "Deployment stage name required when satisfaction_mode is deployment_stage." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, depends_on_job_id: nil, depends_on_epic_id: nil, satisfaction_mode: "success", required_deployment_stage_name: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)
        user = chat_session.user
        satisfaction_mode = satisfaction_mode.presence || "success"
        return Mcp::Tools.invalid("satisfaction_mode must be one of: #{JobDependency::SATISFACTION_MODES.join(', ')}") unless
          JobDependency::SATISFACTION_MODES.include?(satisfaction_mode)

        return Mcp::Tools.invalid("exactly one of depends_on_job_id or depends_on_epic_id must be supplied") if
          depends_on_job_id.nil? == depends_on_epic_id.nil?

        job = user.jobs.find_by(id: job_id)
        return Mcp::Tools.invalid("job not found: #{job_id}") unless job

        if depends_on_job_id
          add_job_target(job, depends_on_job_id, user, satisfaction_mode, required_deployment_stage_name)
        else
          add_epic_target(job, depends_on_epic_id, user, satisfaction_mode, required_deployment_stage_name)
        end
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def add_job_target(job, depends_on_job_id, user, satisfaction_mode, required_deployment_stage_name)
        depends_on_job = user.jobs.find_by(id: depends_on_job_id)
        return Mcp::Tools.invalid("job not found: #{depends_on_job_id}") unless depends_on_job

        dependency = JobDependency.find_or_initialize_by(
          job: job,
          depends_on_job: depends_on_job
        )
        dependency.source = "manual"
        dependency.created_by_user ||= user
        dependency.satisfaction_mode = satisfaction_mode
        dependency.required_deployment_stage_name = required_deployment_stage_name
        dependency.save!

        success_payload(job.reload)
      end

      def add_epic_target(job, depends_on_epic_id, user, satisfaction_mode, required_deployment_stage_name)
        epic = user.epics.find_by(id: depends_on_epic_id)
        return Mcp::Tools.invalid("epic not found: #{depends_on_epic_id}") unless epic

        dependency = JobDependency.find_or_initialize_by(
          job: job,
          depends_on_epic: epic
        )
        dependency.source = "manual"
        dependency.created_by_user ||= user
        dependency.satisfaction_mode = satisfaction_mode
        dependency.required_deployment_stage_name = required_deployment_stage_name
        dependency.save!

        success_payload(job.reload)
      end

      def success_payload(job)
        Mcp::Tools.success(
          job_id: job.id,
          depends_on_job_ids: depends_on_job_ids(job),
          depends_on_epic_ids: depends_on_epic_ids(job),
          dependencies: job.dependencies.order(:id).map { |dependency| dependency_payload(dependency) }
        )
      end

      def depends_on_job_ids(job)
        job.dependencies.where.not(depends_on_job_id: nil).order(:depends_on_job_id).pluck(:depends_on_job_id)
      end

      def depends_on_epic_ids(job)
        job.dependencies.where.not(depends_on_epic_id: nil).order(:depends_on_epic_id).pluck(:depends_on_epic_id)
      end

      def dependency_payload(dependency)
        {
          id: dependency.id,
          depends_on_job_id: dependency.depends_on_job_id,
          depends_on_epic_id: dependency.depends_on_epic_id,
          satisfaction_mode: dependency.satisfaction_mode,
          required_deployment_stage_name: dependency.required_deployment_stage_name
        }.compact
      end
    end
  end
end
