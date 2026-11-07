require "base64"
require "digest"

module ChatAttachments
  class InlineBackfill
    class InvalidAttachment < StandardError; end

    class ContentFormat
      def self.for(owner)
        {
          ChatMessage => StructuredContent,
          ChatQueuedMessage => StructuredContent,
          ChatScratchpadItem => JsonContent
        }.fetch(owner.class).new
      end
    end

    class StructuredContent < ContentFormat
      def serialize(content) = content
    end

    class JsonContent < ContentFormat
      def serialize(content) = JSON.generate(content)
    end

    def initialize(owner)
      @owner = owner
      @content_format = ContentFormat.for(owner)
    end

    def call
      @created = []
      owner.with_lock do
        owner.reload
        rewrite_inline_attachments
      end
    rescue StandardError
      @created.each { |attachment| attachment.file.purge if attachment.file.attached? }
      raise
    end

    private

    attr_reader :owner, :content_format

    def rewrite_inline_attachments
      content = parsed_content
      attachments = Array(content["attachments"])
      return 0 unless attachments.any? { |attachment| inline?(attachment) }

      rewritten = attachments.map.with_index do |attachment, index|
        attributes = attachment.to_h.stringify_keys
        next attributes unless attributes.key?("data")

        @created << build_attachment(attributes, index)
        reference_for(@created.last)
      end

      verify!(@created)
      owner.update!(content: serialize(content.merge("attachments" => rewritten)))
      @created.size
    end

    def parsed_content
      content = owner.content
      content = JSON.parse(content) if content.is_a?(String)
      raise InvalidAttachment, "content is not a JSON object" unless content.is_a?(Hash)

      content.deep_stringify_keys
    rescue JSON::ParserError => e
      raise InvalidAttachment, "content is not valid JSON: #{e.message}"
    end

    def serialize(content)
      content_format.serialize(content)
    end

    def inline?(attachment)
      attachment.respond_to?(:to_h) && attachment.to_h.stringify_keys.key?("data")
    end

    def build_attachment(attributes, index)
      bytes = decode_base64(attributes.fetch("data").to_s, index)
      name = ChatAttachmentPolicy.sanitize_filename(attributes["name"].presence || "attachment-#{index + 1}")
      mime_type = attributes["mime_type"].presence || "application/octet-stream"
      attachment = owner.chat_session.chat_file_attachments.build(
        attachable: owner,
        name: name,
        mime_type: mime_type,
        byte_size: bytes.bytesize,
        checksum: Digest::MD5.base64digest(bytes)
      )
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(bytes),
        filename: name,
        content_type: mime_type
      )
      attachment.file.attach(blob)
      attachment.save!
      attachment.instance_variable_set(:@inline_backfill_expected_byte_size, bytes.bytesize)
      attachment.instance_variable_set(:@inline_backfill_expected_checksum, Digest::MD5.base64digest(bytes))
      attachment
    rescue StandardError
      blob&.purge
      raise
    end

    def decode_base64(data, index)
      Base64.strict_decode64(data)
    rescue ArgumentError => e
      raise InvalidAttachment, "attachment #{index + 1} has malformed base64: #{e.message}"
    end

    def verify!(attachments)
      attachments.each do |attachment|
        bytes = attachment.file.download
        expected_byte_size = attachment.instance_variable_get(:@inline_backfill_expected_byte_size)
        expected_checksum = attachment.instance_variable_get(:@inline_backfill_expected_checksum)
        blob = attachment.file.blob
        next if bytes.bytesize == expected_byte_size && Digest::MD5.base64digest(bytes) == expected_checksum &&
          blob.byte_size == expected_byte_size && blob.checksum == expected_checksum &&
          attachment.byte_size == expected_byte_size && attachment.checksum == expected_checksum

        raise InvalidAttachment, "stored attachment #{attachment.id} failed byte size/checksum verification"
      end
    end

    def reference_for(attachment)
      {
        "id" => attachment.id,
        "name" => attachment.name,
        "mime_type" => attachment.mime_type,
        "size" => attachment.byte_size
      }
    end
  end
end
