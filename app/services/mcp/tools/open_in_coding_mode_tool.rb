require "mcp"

module Mcp::Tools
  class OpenInCodingModeTool < MCP::Tool
    extend JobLifecycleToolSupport

    tool_name "open_in_coding_mode"

    description <<~DESC
      Immediately take over an existing Syrus Job in state
      #{Mcp::ControlToolContracts.states(JobCodingMode::Takeover::CLAIMABLE_JOB_STATES)}
      (or resume the same chat-linked `coding` Job). This requires a Coding Mode
      chat, a recorded pushed branch, repository credentials, no conflicting
      checkout, and no incompatible active workflow ownership. It creates no
      Job, Workflow, WorkUnit, or pending action and enters neither admission
      control nor the worker queue: it links the Job to this chat, checks out its
      recorded branch locally, and moves it to `coding`. Taking over an approved
      Job first removes approval. Use only when the operator explicitly asks.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to open in Coding Mode." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = find_repository_job(chat_session, job_id)
        return error if error

        result = JobCodingMode::Takeover.call(job: job, user: chat_session.user, chat_session: chat_session)

        Mcp::Tools.success(
          job_id: result.job.id,
          job_state: result.job.state,
          branch_name: result.job.branch_name,
          checkout_branch: result.chat_session.coding_checkout_branch,
          repository_slug: result.job.repository.slug,
          message: "#{result.job.slug} is now open in this Coding Mode chat on branch `#{result.job.branch_name}`."
        )
      rescue JobCodingMode::Takeover::Error => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      rescue StandardError => e
        Mcp::Tools.invalid("Could not open Job in Coding Mode: #{e.message}")
      end
    end
  end
end
