require "mcp"

module DesignDocs
  class ReadDesignDocTool < MCP::Tool
    extend ToolSupport

    tool_name "read_design_doc"

    description "Read a Design Doc by DOC-<id>. Workflow agents have read-only access scoped to their run repository; chat agents may read docs visible to the chat user."

    input_schema(
      properties: {
        doc_ref: { type: "string", description: "Canonical Design Doc reference such as DOC-123. A bare numeric id is accepted only for compatibility." },
        detail: {
          type: "string",
          enum: %w[full summary],
          description: "Payload detail level. Omit or pass full for the complete document body, discussion, and suggestions; pass summary for metadata only."
        }
      },
      required: %w[doc_ref]
    )

    class << self
      def call(doc_ref:, server_context:, detail: "full")
        context = context_from(server_context)
        design_doc = find_design_doc!(doc_ref, context)
        detail_mode = DetailMode.for(detail)

        success(
          design_doc: detail_mode.payload(design_doc, context: context),
          read_only: context.run?,
          reference_format: design_doc.display_id
        )
      rescue ActiveRecord::RecordNotFound
        invalid("design doc not found in this agent context: #{doc_ref}. Use DOC-<id> references from list_design_docs.")
      rescue ArgumentError => e
        invalid(e.message)
      rescue StandardError => e
        Rails.logger.error("[DesignDocs::ReadDesignDocTool] #{e.class}: #{e.message}")
        tool_error("Could not read design doc: #{e.message}")
      end
    end

    class DetailMode
      MODES = {
        "full" => "DesignDocs::ReadDesignDocTool::DetailMode::Full",
        "summary" => "DesignDocs::ReadDesignDocTool::DetailMode::Summary"
      }.freeze

      def self.for(value)
        mode = value.to_s
        class_name = MODES[mode]
        raise ArgumentError, "unsupported detail value: #{value.inspect}. Use full or summary." unless class_name

        class_name.constantize.new
      end

      def payload(_design_doc, context:)
        raise NotImplementedError
      end
    end

    class DetailMode::Full < DetailMode
      def payload(design_doc, context:)
        ReadDesignDocTool.detail_payload(design_doc, context: context)
      end
    end

    class DetailMode::Summary < DetailMode
      def payload(design_doc, context:)
        ReadDesignDocTool.metadata_payload(design_doc)
      end
    end
  end
end
