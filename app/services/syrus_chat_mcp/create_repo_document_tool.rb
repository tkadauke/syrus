require "mcp"

module SyrusChatMcp
  class CreateRepoDocumentTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "create_repo_document"

    description "Request creating a repository-scoped text document. The document is not created until the operator confirms the pending action."

    input_schema(
      properties: {
        repository_id: { type: "integer", description: "Repository id that will own the document." },
        title: { type: "string", description: "Document title." },
        body: { type: "string", description: "Document body." }
      },
      required: %w[repository_id title body]
    )

    class << self
      def call(repository_id:, title:, body:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        repository, error = user_repository(chat_session, repository_id)
        return error if error

        title = title.to_s.strip
        body = body.to_s
        return SyrusChatMcp.invalid("title is required") if title.blank?
        return SyrusChatMcp.invalid("body is required") if body.blank?

        create_pending_action!(
          server_context,
          chat_session,
          action: "create_repo_document",
          payload: { "repository_id" => repository.id, "title" => title, "body" => body },
          message: "Create document \"#{title}\" in repository #{repository.id}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
