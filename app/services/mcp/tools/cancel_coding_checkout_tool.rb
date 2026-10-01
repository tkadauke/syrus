require "mcp"

module Mcp::Tools
  class CancelCodingCheckoutTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "cancel_coding_checkout"

    description <<~DESC
      Cancel or detach the active Coding Mode checkout for this chat using the
      existing JobCodingMode::CancelTakeover flow. This discards/releases the
      chat checkout and clears coding takeover state according to backend
      semantics; it does not preserve, migrate, cherry-pick, or apply local
      code changes. If you intend to recover local commits, first preserve them
      yourself with a backup branch or tag.
      Only available when the coding_mode feature is enabled.
    DESC

    input_schema(
      properties: {
        repository_id: {
          type: "integer",
          description: "Repository ID whose Coding Mode checkout should be canceled. Defaults to the chat session's attached repository."
        }
      }
    )

    class << self
      def call(repository_id: nil, server_context:)
        chat_session = server_context.fetch(:chat_session)

        return Mcp::Tools.invalid("Coding Mode is not enabled") unless Feature.coding_mode_enabled?

        repository = resolve_repository(chat_session, repository_id)
        return Mcp::Tools.invalid("repository not found or not accessible") unless repository

        before = ChatWorkspace.coding_reset_status(chat_session, repository)
        result = JobCodingMode::CancelTakeover.call(chat_session: chat_session, repository: repository)
        after = ChatWorkspace.coding_reset_status(result.chat_session, repository)

        Mcp::Tools.success(
          canceled: true,
          repository_id: repository.id,
          repository_slug: repository.slug,
          released_job: released_job_payload(result.job),
          before: before,
          after: after,
          message: message_for(result.job)
        )
      rescue JobCodingMode::CancelTakeover::Error => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def resolve_repository(chat_session, repository_id)
        if repository_id.present?
          chat_session.user.repositories.active.find_by(id: repository_id)
        else
          chat_session.repository
        end
      end

      def released_job_payload(job)
        return nil unless job

        {
          id: job.id,
          slug: job.slug,
          state: job.state,
          branch_name: job.branch_name
        }
      end

      def message_for(job)
        if job
          "#{job.slug} was detached from this Coding Mode chat. No code changes were preserved or applied by this operation."
        else
          "Coding Mode checkout canceled for this chat. No code changes were preserved or applied by this operation."
        end
      end
    end
  end
end
