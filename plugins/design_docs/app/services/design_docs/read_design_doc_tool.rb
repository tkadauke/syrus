require "mcp"

module DesignDocs
  class ReadDesignDocTool < MCP::Tool
    extend ToolSupport

    tool_name "read_design_doc"

    description "Read a Design Doc by DOC-<id>. Full reads page Markdown at up to 64 KiB per call and return a version-pinned continuation cursor. Workflow agents have read-only access scoped to their run repository; chat agents may read docs visible to the chat user."

    input_schema(
      properties: {
        doc_ref: { type: "string", description: "Canonical Design Doc reference such as DOC-123. A bare numeric id is accepted only for compatibility." },
        detail: {
          type: "string",
          enum: %w[full summary],
          description: "Payload detail level. Omit or pass full for a paginated Markdown body (plus discussion and suggestions on the first page); pass summary for metadata only."
        },
        cursor: { type: "string", description: "Opaque next_cursor from the previous read. It pins continuation to that exact Design Doc version." },
        max_bytes: { type: "integer", minimum: DesignDocs::ReadPage::MIN_BYTES, maximum: DesignDocs::ReadPage::MAX_BYTES, description: "Maximum Markdown bytes to return (4 through 65536; default 65536)." },
        version_number: { type: "integer", minimum: 1, description: "Exact Design Doc version to read. Omit to pin a new read to the current version; a cursor already carries this value." }
      },
      required: %w[doc_ref]
    )

    class << self
      def call(doc_ref:, server_context:, detail: "full", cursor: nil, max_bytes: DesignDocs::ReadPage::DEFAULT_MAX_BYTES, version_number: nil)
        context = context_from(server_context)
        design_doc = find_design_doc!(doc_ref, context)
        detail_mode = DetailMode.for(detail)

        success(
          design_doc: detail_mode.payload(
            design_doc,
            context: context,
            cursor: cursor,
            max_bytes: max_bytes,
            version_number: version_number
          ),
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

      def payload(_design_doc, context:, cursor:, max_bytes:, version_number:)
        raise NotImplementedError
      end
    end

    class DetailMode::Full < DetailMode
      def payload(design_doc, context:, cursor:, max_bytes:, version_number:)
        page = DesignDocs::ReadPage.call(
          design_doc: design_doc,
          cursor: cursor,
          max_bytes: max_bytes,
          version_number: version_number
        )
        ReadDesignDocTool.detail_payload(design_doc, context: context, page: page)
      end
    end

    class DetailMode::Summary < DetailMode
      def payload(design_doc, context:, cursor:, max_bytes:, version_number:)
        if cursor.present? || version_number.present? || max_bytes != DesignDocs::ReadPage::DEFAULT_MAX_BYTES
          raise ArgumentError, "cursor, max_bytes, and version_number are only supported with detail: full."
        end

        ReadDesignDocTool.metadata_payload(design_doc)
      end
    end
  end
end
