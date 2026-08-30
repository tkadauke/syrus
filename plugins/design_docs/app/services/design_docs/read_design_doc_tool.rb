require "mcp"

module DesignDocs
  class ReadDesignDocTool < MCP::Tool
    extend ToolSupport

    tool_name "read_design_doc"

    description "Read a Design Doc by DOC-<id>. Workflow agents have read-only access scoped to their run repository; chat agents may read docs visible to the chat user."

    input_schema(
      properties: {
        doc_ref: { type: "string", description: "Canonical Design Doc reference such as DOC-123. A bare numeric id is accepted only for compatibility." }
      },
      required: %w[doc_ref]
    )

    class << self
      def call(doc_ref:, server_context:)
        context = context_from(server_context)
        design_doc = find_design_doc!(doc_ref, context)

        success(
          design_doc: detail_payload(design_doc),
          read_only: context.run?,
          reference_format: design_doc.display_id
        )
      rescue ActiveRecord::RecordNotFound
        invalid("design doc not found in this agent context: #{doc_ref}. Use DOC-<id> references from list_design_docs.")
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::ReadDesignDocTool] #{e.class}: #{e.message}")
        tool_error("Could not read design doc: #{e.message}")
      end
    end
  end
end
