require "base64"

class ChatMediaLibrary
  INLINE_IMAGE_SOURCE_PREFIX = "chat-message-image".freeze

  def self.materialize_inline_images!(chat_session)
    new(chat_session).materialize_inline_images!
  end

  def initialize(chat_session)
    @chat_session = chat_session
    @user = chat_session.user
  end

  def materialize_inline_images!
    inline_image_attachments.each do |message, attachment, index|
      materialize_inline_image!(message, attachment, index)
    end
  end

  private

  attr_reader :chat_session, :user

  def inline_image_attachments
    chat_session.messages.where(role: "user").order(:created_at, :id).flat_map do |message|
      next [] unless message.content.is_a?(Hash)

      Array(message.content["attachments"]).each_with_index.filter_map do |attachment, index|
        mime_type = attachment["mime_type"].to_s
        next unless mime_type.start_with?("image/")
        next if attachment["data"].blank?

        [ message, attachment, index ]
      end
    end
  end

  def materialize_inline_image!(message, attachment, index)
    source_url = inline_image_source_url(message, index)
    document = Document.find_by(attachable: user, source_url: source_url)

    unless document
      document = Document.new(
        kind: "file",
        attachable: user,
        user: user,
        title: attachment_name(attachment, index),
        filename: attachment_name(attachment, index),
        content_type: attachment["mime_type"].to_s,
        byte_size: decoded_attachment_data(attachment).bytesize,
        source_url: source_url
      )
      document.file.attach(
        io: StringIO.new(decoded_attachment_data(attachment)),
        filename: document.filename,
        content_type: document.content_type
      )
      document.save!
    end

    chat_session.chat_attachments.find_or_create_by!(attachable: document)
  rescue StandardError => e
    Rails.logger.warn("[ChatMediaLibrary] skipped inline image for chat #{chat_session.id}: #{e.class}: #{e.message}")
  end

  def inline_image_source_url(message, index)
    "#{INLINE_IMAGE_SOURCE_PREFIX}://#{chat_session.id}/#{message.id}/#{index}"
  end

  def attachment_name(attachment, index)
    attachment["name"].to_s.presence || "chat-image-#{index + 1}#{extension_for(attachment["mime_type"])}"
  end

  def extension_for(mime_type)
    case mime_type.to_s
    when "image/jpeg" then ".jpg"
    when "image/png" then ".png"
    when "image/gif" then ".gif"
    when "image/webp" then ".webp"
    else ""
    end
  end

  def decoded_attachment_data(attachment)
    @decoded_attachment_data ||= {}
    @decoded_attachment_data[attachment.object_id] ||= Base64.decode64(attachment["data"].to_s)
  end
end
