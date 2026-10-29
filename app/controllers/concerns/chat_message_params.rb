# Incoming chat-message request-param parsing extracted from
# Api::V1::App::ChatsController: reading the message text / attachments,
# sanitizing attachment params, and the chat-name / bookmark-label readers.
# Pure params helpers, mixed straight back in. Kept private on include.
module ChatMessageParams
  private

  CHAT_ATTACHMENT_MAX_BYTES = 5.megabytes
  CHAT_ATTACHMENT_TOTAL_MAX_BYTES = 20.megabytes


  def message_text
    (params[:content].presence || params.dig(:chat_message, :text)).to_s.strip
  end

  # A message may carry files with no text — the attachment is the message.
  # The blank-text guard uses this to allow that.
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
      render_error("validation_failed", I18n.t("server.errors.chat_attachments.must_be_array"), status: :unprocessable_content)
      return
    end

    total_bytes = 0
    sanitized = attachments.map do |attachment|
      attributes = attachment.respond_to?(:to_unsafe_h) ? attachment.to_unsafe_h : attachment
      unless attributes.respond_to?(:[])
        render_error("validation_failed", I18n.t("server.errors.chat_attachments.must_be_objects"), status: :unprocessable_content)
        return
      end

      name = attributes["name"] || attributes[:name]
      mime_type = (attributes["mime_type"] || attributes[:mime_type]).to_s
      data = (attributes["data"] || attributes[:data]).to_s

      policy = ChatAttachmentPolicy.check(filename: name, mime_type: mime_type)
      display_name = name.to_s.presence || I18n.t("server.errors.chat_attachments.default_name")
      unless policy.accepted?
        render_error("validation_failed", I18n.t("server.errors.chat_attachments.unsupported_type", name: display_name), status: :unprocessable_content)
        return
      end

      begin
        decoded = Base64.strict_decode64(data)
      rescue ArgumentError
        render_error("validation_failed", I18n.t("server.errors.chat_attachments.malformed_base64", name: display_name), status: :unprocessable_content)
        return
      end

      if decoded.bytesize > CHAT_ATTACHMENT_MAX_BYTES
        render_error("validation_failed", I18n.t("server.errors.chat_attachments.file_too_large"), status: :unprocessable_content)
        return
      end

      if policy.text? && !ChatAttachmentPolicy.valid_text?(decoded)
        render_error("validation_failed", I18n.t("server.errors.chat_attachments.invalid_utf8", name: display_name), status: :unprocessable_content)
        return
      end

      total_bytes += decoded.bytesize

      { "name" => ChatAttachmentPolicy.sanitize_filename(name), "mime_type" => policy.mime_type, "data" => Base64.strict_encode64(decoded) }
    end


    if total_bytes > CHAT_ATTACHMENT_TOTAL_MAX_BYTES
      render_error("validation_failed", I18n.t("server.errors.chat_attachments.total_too_large"), status: :unprocessable_content)
      return
    end

    sanitized
  end

  def chat_name
    (params[:name].presence || params.dig(:chat, :name).presence || params.dig(:chat, :title)).to_s.strip
  end

  def bookmark_label
    params.dig(:chat_bookmark, :label).to_s.strip
  end
end
