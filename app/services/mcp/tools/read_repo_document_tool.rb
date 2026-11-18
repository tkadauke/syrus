require "base64"
require "mcp"
require "pdf/reader"

module Mcp::Tools
  class ReadRepoDocumentTool < MCP::Tool
    MAX_TEXT_BYTES = 64.kilobytes
    IMAGE_CONTENT_TYPES = %w[
      image/png
      image/jpeg
      image/gif
      image/webp
      image/svg+xml
    ].freeze
    DOCX_CONTENT_TYPES = [
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    ].freeze

    tool_name "read_repo_document"

    description "Read a supporting document available to this chat session."

    input_schema(
      properties: {
        id: { type: "integer", description: "Document id to read." }
      },
      required: %w[id]
    )

    class << self
      def call(id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        document = chat_session.attached_documents_in_scope.with_attached_file.find_by(id: id)
        return Mcp::Tools.invalid("document not found in this chat session's attachments: #{id}") unless document

        read_file(document)
      rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
        Mcp::Tools.tool_error("Could not extract PDF text: #{e.message}")
      rescue StandardError => e
        Mcp::Tools.tool_error("Could not read document: #{e.message}")
      end

      private

      def read_file(document)
        return Mcp::Tools.invalid("file is not attached") unless document.file.attached?

        content_type = document.content_type.to_s
        if image_content_type?(content_type)
          return MCP::Tool::Response.new([
            {
              type: "image",
              data: Base64.strict_encode64(document.file.download),
              mimeType: content_type
            }
          ])
        end

        text = extract_file_text(document, content_type)
        MCP::Tool::Response.new([ text_block(capped_text(text)) ])
      end

      def extract_file_text(document, content_type)
        if content_type.start_with?("text/")
          document.file.download.force_encoding("UTF-8").encode("UTF-8", invalid: :replace, undef: :replace)
        elsif content_type == "application/pdf"
          extract_pdf_text(document)
        elsif DOCX_CONTENT_TYPES.include?(content_type)
          extract_docx_text(document)
        else
          raise ArgumentError, "unsupported file content type: #{content_type}"
        end
      end

      def extract_pdf_text(document)
        document.file.open do |file|
          PDF::Reader.new(file.path).pages.map(&:text).join("\n\n")
        end
      end

      def extract_docx_text(document)
        require "docx"

        document.file.open do |file|
          Docx::Document.open(file.path).paragraphs.map(&:text).join("\n")
        end
      rescue LoadError
        raise ArgumentError, "DOCX support is not available"
      end

      def capped_text(text)
        text = text.to_s
        return text if text.bytesize <= MAX_TEXT_BYTES

        omitted = text.bytesize - MAX_TEXT_BYTES
        note = "\n\n[Document truncated after #{MAX_TEXT_BYTES} bytes; omitted #{omitted} bytes.]"
        head_bytes = MAX_TEXT_BYTES - note.bytesize
        "#{text.safe_byteslice(0, head_bytes)}#{note}"
      end

      def text_block(text)
        { type: "text", text: text }
      end

      def image_content_type?(content_type)
        IMAGE_CONTENT_TYPES.include?(content_type)
      end
    end
  end
end
