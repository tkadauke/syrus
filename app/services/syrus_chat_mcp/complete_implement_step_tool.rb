require "mcp"

module SyrusChatMcp
  # Signals that coding is complete and hands off to Syrus automation.
  # Releases the coding lock on the linked Job and fires a coding_handoff
  # workflow that runs graders and (on pass) opens the PR. Results are
  # posted back to this chat session as a system message and trigger a new
  # agent turn.
  #
  # On grader failure: call this tool again after fixing the issues to
  # re-run graders. The chat stays in coding mode with the same Job linked.
  #
  # Only available when the coding_mode feature flag is on and this chat
  # session is in coding mode. See Sidecar#tools_for_session.
  class CompleteImplementStepTool < MCP::Tool
    tool_name "complete_implement_step"

    description <<~DESC.strip
      Signal that your coding changes are complete and trigger grader verification.
      Graders run on the current branch; if they pass, the PR is opened and results are posted here.
      If graders fail, the report is posted here for you to address — fix the issues and call this tool again.
    DESC

    input_schema(
      properties: {}
    )

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)

        unless Feature.coding_mode_enabled?
          return SyrusChatMcp.success(status: "error", message: "coding_mode feature is not enabled")
        end

        unless chat_session.coding?
          return SyrusChatMcp.success(status: "error", message: "chat session is not in coding mode")
        end

        job = Job.find_by(linked_chat_id: chat_session.id)
        return SyrusChatMcp.success(status: "error", message: "no job is linked to this coding session") unless job
        return SyrusChatMcp.success(status: "error", message: "job #{job.slug} is not in coding state (current: #{job.state})") unless job.coding?

        workflow = job.start_coding_handoff!
        unless workflow
          return SyrusChatMcp.success(status: "error", message: "could not start grader run — job state incompatible")
        end

        SyrusChatMcp.success(
          job_id: job.id,
          job_slug: App::Presentation.job_slug(job),
          workflow_id: workflow.id,
          message: "Graders are running. Results will be posted here when complete."
        )
      end
    end
  end
end
