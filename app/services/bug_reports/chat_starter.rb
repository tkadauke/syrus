require "base64"

module BugReports
  class ChatStarter
    include BugReports::ContextFormatter

    CHAT_ATTACHMENT_MIME_TYPES = ChatMessageParams::CHAT_ATTACHMENT_ALLOWED_MIME_TYPES.freeze
    INLINE_TEXT_MIME_TYPES = %w[
      text/plain
      text/markdown
      text/x-markdown
      image/svg+xml
    ].freeze
    INLINE_TEXT_MAX_BYTES = 200_000

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
      inline_sections = []
      append_upload!(chat_attachments, inline_sections, screenshot) if screenshot.present?
      extra.each do |attachment|
        append_upload!(chat_attachments, inline_sections, attachment)
      end
      prompt_text += inline_sections.join

      chat_session = nil
      user_message = nil
      ApplicationRecord.transaction do
        chat_session = ChatSession.create!(
          user: user,
          repository: repository,
          title: nil,
          last_message_at: Time.current
        )
        content = { "text" => prompt_text }
        content["attachments"] = chat_attachments if chat_attachments.any?
        user_message = chat_session.messages.create!(role: "user", content: content, sender_user_id: user.id)
        chat_session.pin_chat_provider!
      end

      ChatTitleJob.perform_later(chat_session.id, user_message.id)
      ChatTurnJob.perform_later(chat_session.id, user_message.id) if chat_session.should_trigger_agent?(prompt_text)

      Result.new(chat_session: chat_session)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    end

    private

    attr_reader :user, :repository

    def failure(error)
      Result.new(error: error)
    end

    def append_upload!(chat_attachments, inline_sections, upload)
      body = upload.read
      filename = upload.original_filename.presence || "attachment"
      content_type = upload.content_type.presence || "application/octet-stream"

      if CHAT_ATTACHMENT_MIME_TYPES.include?(content_type)
        if Base64.strict_encode64(body).bytesize > ChatMessageParams::CHAT_ATTACHMENT_MAX_BASE64_BYTES
          inline_sections << omitted_attachment_section(filename, "larger than chat's inline attachment limit")
          return
        end

        chat_attachments << {
          "name" => filename,
          "mime_type" => content_type,
          "data" => Base64.strict_encode64(body)
        }
        return
      end

      if INLINE_TEXT_MIME_TYPES.include?(content_type) && body.bytesize <= INLINE_TEXT_MAX_BYTES
        inline_sections << inline_text_attachment_section(filename, body.force_encoding("UTF-8").scrub)
      else
        inline_sections << omitted_attachment_section(filename, "unsupported chat attachment type #{content_type}")
      end
    end

    def inline_text_attachment_section(filename, body)
      "\n\n## #{filename}\n\n```text\n#{body}\n```"
    end

    def omitted_attachment_section(filename, reason)
      "\n\n## #{filename}\n\nAttachment not inlined: #{reason}."
    end
  end
end
