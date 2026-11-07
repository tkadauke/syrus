module DesignDocs
  class ReadPage
    DEFAULT_MAX_BYTES = 64.kilobytes
    MAX_BYTES = 64.kilobytes
    MIN_BYTES = 4

    Result = Data.define(
      :version,
      :markdown,
      :rendered_markdown,
      :total_bytes,
      :start_offset,
      :end_offset,
      :truncated,
      :next_cursor,
      :first_page
    )

    class << self
      def call(design_doc:, cursor: nil, max_bytes: DEFAULT_MAX_BYTES, version_number: nil)
        requested_max = Integer(max_bytes)
        unless requested_max.between?(MIN_BYTES, MAX_BYTES)
          raise ArgumentError, "max_bytes must be between #{MIN_BYTES} and #{MAX_BYTES}."
        end

        cursor_data = decode_cursor(cursor) if cursor.present?
        validate_cursor!(cursor_data, design_doc, version_number) if cursor_data

        pinned_version_number = cursor_data&.fetch("version_number") || version_number || design_doc.current_version&.version_number
        raise ArgumentError, "design doc has no readable version." unless pinned_version_number

        version = design_doc.versions.find_by(version_number: pinned_version_number)
        raise ArgumentError, "version_number #{pinned_version_number} does not exist for #{design_doc.display_id}." unless version

        source = version.markdown.to_s
        start_offset = cursor_data&.fetch("offset") || 0
        raise ArgumentError, "cursor offset is outside the pinned Design Doc version." unless start_offset.between?(0, source.bytesize)

        markdown = utf8_page(source, start_offset, requested_max)
        end_offset = start_offset + markdown.bytesize
        truncated = end_offset < source.bytesize

        Result.new(
          version: version,
          markdown: markdown,
          rendered_markdown: DesignDocs::AnchorMarkers.strip(markdown),
          total_bytes: source.bytesize,
          start_offset: start_offset,
          end_offset: end_offset,
          truncated: truncated,
          next_cursor: truncated ? encode_cursor(design_doc.id, version.version_number, end_offset) : nil,
          first_page: start_offset.zero?
        )
      rescue ActiveSupport::MessageVerifier::InvalidSignature, JSON::ParserError, TypeError
        raise ArgumentError, "cursor is invalid or has been tampered with. Start a new read without a cursor."
      end

      private

      def utf8_page(source, start_offset, max_bytes)
        candidate = source.byteslice(start_offset, max_bytes).to_s
        candidate = candidate.byteslice(0, candidate.bytesize - 1).to_s until candidate.valid_encoding?
        raise ArgumentError, "max_bytes is too small to make UTF-8-safe forward progress." if candidate.empty? && start_offset < source.bytesize

        candidate
      end

      def encode_cursor(design_doc_id, version_number, offset)
        verifier.generate({ design_doc_id: design_doc_id, version_number: version_number, offset: offset })
      end

      def decode_cursor(cursor)
        value = verifier.verify(cursor.to_s)
        raise ActiveSupport::MessageVerifier::InvalidSignature unless value.is_a?(Hash)

        value.stringify_keys
      end

      def validate_cursor!(cursor_data, design_doc, requested_version_number)
        unless cursor_data.keys.sort == %w[design_doc_id offset version_number] &&
            cursor_data["design_doc_id"] == design_doc.id &&
            cursor_data["version_number"].is_a?(Integer) &&
            cursor_data["offset"].is_a?(Integer)
          raise ArgumentError, "cursor is invalid for #{design_doc.display_id}. Start a new read without a cursor."
        end

        return if requested_version_number.nil? || Integer(requested_version_number) == cursor_data["version_number"]

        raise ArgumentError, "cursor is pinned to version #{cursor_data["version_number"]}, not version #{requested_version_number}."
      end

      def verifier
        Rails.application.message_verifier("design-doc-read-pagination")
      end
    end
  end
end
