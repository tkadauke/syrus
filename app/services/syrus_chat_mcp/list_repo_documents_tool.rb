require "mcp"

module SyrusChatMcp
  class ListRepoDocumentsTool < MCP::Tool
    tool_name "list_repo_documents"

    description "List supporting documents attached to this chat session's repository."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        repository = server_context.fetch(:chat_session).repository
        documents = repository.repository_documents.with_attached_file.order(:created_at, :id)

        MCP::Tool::Response.new([
          { type: "text", text: JSON.generate(documents.map { |document| document_payload(document) }) }
        ])
      end

      private

      def document_payload(document)
        payload = {
          id: document.id,
          kind: document.kind,
          title: document.title
        }

        if document.file?
          payload[:content_type] = document.content_type
          payload[:size_bytes] = document.file.byte_size if document.file.attached?
        else
          payload[:url] = document.google_docs_url
        end

        payload
      end
    end
  end
end
