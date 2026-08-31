class ChatDraftContent
  MEDIA_KEYS = %w[attachments video_walkthrough_id source].freeze

  attr_reader :text, :attachments, :metadata

  def self.from_content(content)
    parsed = parse_json_object(content)
    return from_hash(parsed) if parsed
    return from_hash(content) if content.is_a?(Hash)

    new(text: content.to_s)
  end

  def self.from_hash(content)
    hash = content.respond_to?(:to_unsafe_h) ? content.to_unsafe_h : content
    text = (hash["text"] || hash[:text] || hash["content"] || hash[:content]).to_s.strip
    attachments = hash["attachments"] || hash[:attachments] || []
    metadata = {}

    MEDIA_KEYS.each do |key|
      value = hash[key] || hash[key.to_sym]
      metadata[key] = value if value.present? && key != "attachments"
    end

    new(text: text, attachments: attachments, metadata: metadata)
  end

  def self.parse_json_object(content)
    return unless content.is_a?(String)

    parsed = JSON.parse(content)
    parsed if parsed.is_a?(Hash) && (parsed.key?("text") || MEDIA_KEYS.any? { |key| parsed.key?(key) })
  rescue JSON::ParserError
    nil
  end

  def initialize(text:, attachments: [], metadata: {})
    @text = text.to_s
    @attachments = Array(attachments).map { |attachment| normalize_attachment(attachment) }
    @metadata = metadata.stringify_keys
  end

  def media?
    attachments.present? || metadata["video_walkthrough_id"].present?
  end

  def present?
    text.present? || media?
  end

  def to_message_content
    { "text" => text }.tap do |content|
      content["attachments"] = attachments if attachments.present?
      metadata.each { |key, value| content[key] = value if value.present? }
    end
  end

  def to_scratchpad_content
    media? ? JSON.generate(to_message_content) : text
  end

  def payload
    { content: text, text: text, attachments: attachments }
  end

  private

  def normalize_attachment(attachment)
    attributes = attachment.respond_to?(:to_unsafe_h) ? attachment.to_unsafe_h : attachment
    attributes = {} unless attributes.respond_to?(:stringify_keys)
    attributes = attributes.stringify_keys
    {
      "name" => attributes["name"].to_s,
      "mime_type" => (attributes["mime_type"] || attributes["mimeType"]).to_s,
      "data" => attributes["data"].to_s
    }
  end
end
