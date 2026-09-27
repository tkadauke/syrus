require "mcp"

module DesignDocs
  class ListDesignDocSectionsTool < MCP::Tool
    extend ToolSupport

    tool_name "list_design_doc_sections"

    description "List the Markdown heading outline for a Design Doc by DOC-<id>, including offsets that can be used with suggest_design_doc_change."

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
        rendered_markdown = DesignDocs::AnchorMarkers.strip(design_doc.markdown)

        success(
          design_doc: list_payload(design_doc),
          sections: section_payloads(rendered_markdown),
          read_only: context.run?,
          reference_format: design_doc.display_id
        )
      rescue ActiveRecord::RecordNotFound
        invalid("design doc not found in this agent context: #{doc_ref}. Use DOC-<id> references from list_design_docs.")
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::ListDesignDocSectionsTool] #{e.class}: #{e.message}")
        tool_error("Could not list design doc sections: #{e.message}")
      end

      private

      def section_payloads(rendered_markdown)
        DesignDocs::MarkdownBlocks.heading_sections(rendered_markdown).map do |section|
          {
            text: section.text,
            level: section.level,
            start_offset: section.start_offset,
            end_offset: section.end_offset
          }
        end
      end
    end
  end
end
