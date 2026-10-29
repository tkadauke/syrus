require "base64"

module BugReports
  class ChatStarter
    include BugReports::ContextFormatter

    class InvalidAttachment < StandardError; end

    Result = Struct.new(:chat_session, :error, keyword_init: true) do
      def success?
        chat_session.present? && error.blank?
      end
    end

    def initialize(user:, repository:)
      @user = user
      @repository = repository
    end

    def call(title:, description:, screenshot: nil, attachments: [], context: nil)
      title = title.to_s.strip.presence || "In-app bug report"
      description = description.to_s.strip

      if screenshot.present? && screenshot.content_type != "image/png"
        return failure("Screenshot must be a PNG.")
      end

      extra = Array(attachments).select(&:present?)
      total = (screenshot.present? ? 1 : 0) + extra.size
      if total > Document::MAX_ATTACHMENTS_PER_JOB
        return failure("Too many attachments. Bug report chats can have at most #{Document::MAX_ATTACHMENTS_PER_JOB} files.")
      end

      prompt_text = [ "Chat about this bug report: #{title}", description ].reject(&:blank?).join("\n\n")
      prompt_text += format_context_markdown(context)

      chat_attachments = []
      @attachment_total_bytes = 0
      append_upload!(chat_attachments, screenshot) if screenshot.present?
      extra.each do |attachment|
        append_upload!(chat_attachments, attachment)
      end

      chat_session = nil
      user_message = nil
      turn_triggered = false
      ApplicationRecord.transaction do
        chat_session = ChatSession.create!(
          user: user,
          repository: repository,
          title: nil,
          last_message_at: Time.current
        )
        content = { "text" => prompt_text }
        content["attachments"] = chat_attachments if chat_attachments.any?
        mentions = chat_session.resolve_mentions(prompt_text)
        turn_triggered = chat_session.should_trigger_agent?(mentions)
        user_message = chat_session.messages.create!(
          role: "user",
          content: content,
          mentions: mentions,
          sender_user_id: user.id,
          skip_turn_trigger: !turn_triggered
        )
        chat_session.pin_chat_provider!
      end

      ChatTitleJob.perform_later(chat_session.id, user_message.id)
      ChatTurnJob.perform_later(chat_session.id, user_message.id) if turn_triggered

      Result.new(chat_session: chat_session)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    rescue InvalidAttachment => e
      failure(e.message)
    end

    private

    attr_reader :user, :repository

    def failure(error)
      Result.new(error: error)
    end

    def append_upload!(chat_attachments, upload)
      body = upload.read
      filename = upload.original_filename.presence || "attachment"
      content_type = upload.content_type.presence || "application/octet-stream"

      policy = ChatAttachmentPolicy.check(filename: filename, mime_type: content_type)
      raise InvalidAttachment, "#{filename} is not a supported attachment type." unless policy.accepted?
      if policy.text? && !ChatAttachmentPolicy.valid_text?(body)
        raise InvalidAttachment, "#{filename} is not valid UTF-8 text."
      end
      if body.bytesize > ChatMessageParams::CHAT_ATTACHMENT_MAX_BYTES
        raise InvalidAttachment, "Each attachment must be 5 MB or smaller."
      end

      @attachment_total_bytes += body.bytesize
      if @attachment_total_bytes > ChatMessageParams::CHAT_ATTACHMENT_TOTAL_MAX_BYTES
        raise InvalidAttachment, "Attachments must total 20 MB or less."
      end

      chat_attachments << {
        "name" => ChatAttachmentPolicy.sanitize_filename(filename),
        "mime_type" => policy.mime_type,
        "data" => Base64.strict_encode64(body)
      }
    end
  end
end
