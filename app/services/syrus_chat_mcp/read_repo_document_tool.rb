require "base64"
require "mcp"
require "net/http"
require "openssl"
require "pdf/reader"
require "uri"

module SyrusChatMcp
  class ReadRepoDocumentTool < MCP::Tool
    MAX_TEXT_BYTES = 64.kilobytes
    GOOGLE_DOC_CACHE_TTL = 1.hour
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
        return SyrusChatMcp.invalid("document not found in this chat session's attachments: #{id}") unless document

        if document.file?
          read_file(document)
        else
          read_google_doc(document)
        end
      rescue PDF::Reader::MalformedPDFError, PDF::Reader::UnsupportedFeatureError => e
        SyrusChatMcp.tool_error("Could not extract PDF text: #{e.message}")
      rescue StandardError => e
        SyrusChatMcp.tool_error("Could not read document: #{e.message}")
      end

      private

      def read_file(document)
        return SyrusChatMcp.invalid("file is not attached") unless document.file.attached?

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

      def read_google_doc(document)
        if document.content_cache.present? && document.content_cached_at && document.content_cached_at > GOOGLE_DOC_CACHE_TTL.ago
          return MCP::Tool::Response.new([ text_block(document.content_cache) ])
        end

        text = fetch_google_doc_text(document.google_docs_url)
        capped = capped_text(text)
        document.update!(content_cache: capped, content_cached_at: Time.current)

        MCP::Tool::Response.new([ text_block(capped) ])
      rescue URI::InvalidURIError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, RuntimeError => e
        google_doc_error(e.message)
      rescue ActiveRecord::RecordInvalid => e
        google_doc_error(e.record.errors.full_messages.to_sentence)
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

      def fetch_google_doc_text(url)
        uri = URI.parse(google_doc_export_url(url))
        response = Net::HTTP.get_response(uri)
        return response.body if response.is_a?(Net::HTTPSuccess)

        raise "Google Doc export returned HTTP #{response.code}"
      end

      def google_doc_export_url(url)
        clean = url.to_s.strip
        clean = clean.split("#", 2).first.to_s.split("?", 2).first.to_s
        clean = clean.delete_suffix("/edit")
        clean = clean.delete_suffix("/")
        return "#{clean}?format=txt" if clean.end_with?("/export")

        "#{clean}/export?format=txt"
      end

      def capped_text(text)
        text = text.to_s
        return text if text.bytesize <= MAX_TEXT_BYTES

        omitted = text.bytesize - MAX_TEXT_BYTES
        note = "\n\n[Document truncated after #{MAX_TEXT_BYTES} bytes; omitted #{omitted} bytes.]"
        head_bytes = MAX_TEXT_BYTES - note.bytesize
        "#{SyrusChatMcp.safe_byteslice(text, 0, head_bytes)}#{note}"
      end

      def text_block(text)
        { type: "text", text: text }
      end

      def image_content_type?(content_type)
        IMAGE_CONTENT_TYPES.include?(content_type)
      end

      def google_doc_error(message)
        SyrusChatMcp.tool_error(
          "Could not fetch Google Doc text: #{message}. Check that the document is shared publicly or with anyone who has the link."
        )
      end
    end
  end
end
