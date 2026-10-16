# Incoming chat-message request-param parsing extracted from
# Api::V1::App::ChatsController: reading the message text / attachments,
# sanitizing attachment params, and the chat-name / bookmark-label readers.
# Pure params helpers, mixed straight back in. Kept private on include.
module ChatMessageParams
  private

  CHAT_ATTACHMENT_ALLOWED_MIME_TYPES = JSON.parse(Rails.root.join("config/chat_attachment_mime_types.json").read).freeze
  CHAT_ATTACHMENT_MAX_BASE64_BYTES = 7.megabytes


  def message_text
    (params[:content].presence || params.dig(:chat_message, :text)).to_s.strip
  end

  # A message may carry media (image/PDF attachments) with no text — the
  # media is the message. The blank-text guard uses this to allow that.
  def message_has_attachments?
    params.dig(:chat_message, :attachments).present?
  end

  def message_content(text)
    content = { "text" => text }
    attachments = params.dig(:chat_message, :attachments)
    return content if attachments.blank?

    sanitized = sanitized_attachments(attachments)
    return if performed?

    content["attachments"] = sanitized
    content
  end

  def sanitized_attachments(attachments)
    unless attachments.is_a?(Array)
      render_error("validation_failed", "Attachments must be an array.", status: :unprocessable_content)
      return
    end

    attachments.map do |attachment|
      attributes = attachment.respond_to?(:to_unsafe_h) ? attachment.to_unsafe_h : attachment
      unless attributes.respond_to?(:[])
        render_error("validation_failed", "Attachments must be objects.", status: :unprocessable_content)
        return
      end

      name = attributes["name"] || attributes[:name]
      mime_type = (attributes["mime_type"] || attributes[:mime_type]).to_s
      data = (attributes["data"] || attributes[:data]).to_s

      unless CHAT_ATTACHMENT_ALLOWED_MIME_TYPES.include?(mime_type)
        render_error("validation_failed", "#{name.to_s.presence || "Attachment"} is not a supported type (images or PDF).", status: :unprocessable_content)
        return
      end

      if data.bytesize > CHAT_ATTACHMENT_MAX_BASE64_BYTES
        render_error("validation_failed", "Attachment data must be 7 MB or smaller.", status: :unprocessable_content)
        return
      end

      { "name" => name.to_s, "mime_type" => mime_type, "data" => data }
    end
  end

  def chat_name
    (params[:name].presence || params.dig(:chat, :name).presence || params.dig(:chat, :title)).to_s.strip
  end

  def bookmark_label
    params.dig(:chat_bookmark, :label).to_s.strip
  end
end
