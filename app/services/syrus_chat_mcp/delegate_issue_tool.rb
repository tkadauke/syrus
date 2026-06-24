require "mcp"

module SyrusChatMcp
  class DelegateIssueTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "delegate_issue"

    description "Request delegating a GitHub issue to Syrus by adding the repository trigger label. The label is not added until the operator confirms the pending action."

    input_schema(
      properties: {
        repository_id: { type: "integer", description: "Repository id containing the issue." },
        issue_number: { type: "integer", description: "GitHub issue number to delegate." }
      },
      required: %w[repository_id issue_number]
    )

    class << self
      def call(repository_id:, issue_number:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        repository, error = user_repository(chat_session, repository_id)
        return error if error

        issue_number = Integer(issue_number, exception: false)
        return SyrusChatMcp.invalid("issue_number is required") unless issue_number&.positive?

        create_pending_action!(
          server_context,
          chat_session,
          action: "delegate_issue",
          payload: { "repository_id" => repository.id, "issue_number" => issue_number },
          message: "Delegate issue ##{issue_number} in #{repository.slug} to Syrus?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
