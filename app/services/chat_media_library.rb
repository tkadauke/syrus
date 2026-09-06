require "base64"

class ChatMediaLibrary
  INLINE_IMAGE_SOURCE_PREFIX = "chat-message-image".freeze

  # Batch size for any_inline_images? -- kept small enough that a chat with
  # no image attachments (the common case for most mutating requests, which
  # rebuild the full chat payload on every send/rename/pin/etc.) doesn't pull
  # its entire message history's content (including any accumulated base64
  # attachment data -- materialize_inline_image! copies it into a Document
  # but never clears it from the source message) into memory at once, and a
  # chat that does have one stops scanning as soon as the first batch finds it.
  EXISTENCE_CHECK_BATCH_SIZE = 200

  def self.materialize_inline_images!(chat_session)
    new(chat_session).materialize_inline_images!
  end

  # Cheap existence check for "does this chat have any inline image
  # attachments anywhere in its history" -- used to decide whether the media
  # tab/panel should even be shown. Deliberately separate from
  # materialize_inline_images!'s full scan-and-attach: callers here (built
  # into the chat payload on essentially every mutation) only ever need a
  # boolean, not Document materialization or the message/attachment/index
  # detail inline_image_attachments returns.
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
    chat_session.messages.where(role: "user").in_batches(of: EXISTENCE_CHECK_BATCH_SIZE) do |relation|
      return true if relation.pluck(:content).any? { |content| content_has_image_attachment?(content) }
    end

    false
  end

  private

  attr_reader :chat_session, :user

  def inline_image_attachments
    chat_session.messages.where(role: "user").order(:created_at, :id).flat_map do |message|
      next [] unless message.content.is_a?(Hash)

      image_attachment_entries(message.content).map { |attachment, index| [ message, attachment, index ] }
    end
  end

  def content_has_image_attachment?(content)
    content.is_a?(Hash) && image_attachment_entries(content).any?
  end

  # Shared "is this an image attachment worth materializing/counting"
  # predicate for both inline_image_attachments and any_inline_images?, so
  # the two scans can't silently drift apart on what counts as an image.
  def image_attachment_entries(content)
    Array(content["attachments"]).each_with_index.filter_map do |attachment, index|
      mime_type = attachment["mime_type"].to_s
      next unless mime_type.start_with?("image/")
      next if attachment["data"].blank?

      [ attachment, index ]
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
