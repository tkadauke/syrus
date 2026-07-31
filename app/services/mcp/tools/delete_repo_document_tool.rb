require "mcp"

module Mcp::Tools
  class DeleteRepoDocumentTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "delete_repo_document"

    description "Request deleting a repository-scoped document. The document is not deleted until the operator confirms the pending action."

    input_schema(
      properties: {
        document_id: { type: "integer", description: "Repository document id to delete." }
      },
      required: %w[document_id]
    )

    class << self
      def call(document_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        document, error = user_document(chat_session, document_id)
        return error if error

        create_pending_action!(
          server_context,
          chat_session,
          action: "delete_repo_document",
          payload: { "document_id" => document.id, "title" => document.title },
          message: "Delete document \"#{document.title}\"?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
