require "mcp"

module DesignDocs
  class ListDesignDocsTool < MCP::Tool
    extend McpToolSupport

    tool_name "list_design_docs"

    description <<~DESC
      List readable design docs for this context. Results use canonical DOC-<id> references; pass one to read_design_doc for Markdown.
      Chat agents see docs visible to the chat user, optionally narrowed by repository_id. Worker agents see only docs visible through their run's user/repository context.
    DESC

    input_schema(
      type: "object",
      required: [],
      properties: {
        repository_id: { type: "integer", description: "Optional repository id to narrow chat results. Worker calls are always narrowed to the run repository." }
      }
    )

    class << self
      def call(user: nil, repository: nil, repository_id: nil, chat_session: nil, server_context: nil)
        user ||= chat_session&.user
        return error_response("No user available in this context.") unless user

        requested_repository = repository || repository_from_id(user, repository_id)
        if repository_id.present? && requested_repository.nil?
          return error_response("repository not found or not accessible in this context: #{repository_id}")
        end

        scope = readable_scope(user: user, repository: requested_repository).newest_first.limit(50)

        ok_response(
          design_docs: scope.map { |design_doc| design_doc_summary(design_doc) },
          repository_id: requested_repository&.id,
          references: "Use DOC-<id> values with read_design_doc."
        )
      end
    end
  end
end
