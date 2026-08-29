require "mcp"

module DesignDocs
  class ReadDesignDocTool < MCP::Tool
    extend McpToolSupport

    tool_name "read_design_doc"

    description <<~DESC
      Read one design doc by canonical DOC-<id> reference or integer id. Returns canonical Markdown plus comments and pending suggestions when readable in this context.
      This tool is read-only and never mutates document content.
    DESC

    input_schema(
      type: "object",
      required: %w[doc_ref],
      properties: {
        doc_ref: { type: "string", description: doc_ref_description }
      }
    )

    class << self
      def call(user: nil, repository: nil, chat_session: nil, server_context: nil, doc_ref:)
        user ||= chat_session&.user
        return error_response("No user available in this context.") unless user

        design_doc = doc_from_ref(doc_ref, scope: readable_scope(user: user, repository: repository))
        return error_response("design doc not found or not readable in this context: #{doc_ref}") unless design_doc

        ok_response(design_doc: design_doc_detail(design_doc))
      end
    end
  end
end
