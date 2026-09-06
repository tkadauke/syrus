require "base64"

class ChatMediaLibrary
  INLINE_IMAGE_SOURCE_PREFIX = "chat-message-image".freeze

  def self.materialize_inline_images!(chat_session)
    new(chat_session).materialize_inline_images!
  end

  # Existence-only check over the chat's full message history (unlike the
  # loaded/paginated message window the chat payload sends the frontend) --
  # e.g. "does the sidebar Media tab have anything to show." Reuses the same
  # attachment predicate as #inline_image_attachments but stops scanning at
  # the first match instead of collecting every attachment across the chat,
  # since callers only need a boolean and this runs on most chat payload
  # builds, not just when the Media tab is opened.
  def self.any_inline_images?(chat_session)
    new(chat_session).any_inline_images?
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

  def any_inline_images?
    chat_session.messages.where(role: "user").find_each(batch_size: 50) do |message|
      return true if image_attachments_in(message).any?
    end
    false
  end

  private

  attr_reader :chat_session, :user

  def inline_image_attachments
    chat_session.messages.where(role: "user").order(:created_at, :id).flat_map do |message|
      image_attachments_in(message).map { |attachment, index| [ message, attachment, index ] }
    end
  end

  def image_attachments_in(message)
    return [] unless message.content.is_a?(Hash)

    Array(message.content["attachments"]).each_with_index.filter_map do |attachment, index|
      next unless image_attachment?(attachment)

      [ attachment, index ]
    end
  end

  def image_attachment?(attachment)
    attachment["mime_type"].to_s.start_with?("image/") && attachment["data"].present?
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
