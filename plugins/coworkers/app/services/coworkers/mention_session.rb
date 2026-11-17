class Coworkers::MentionSession
  INITIAL_CONTEXT_MESSAGES = 20

  class << self
    def find_or_create!(coworker:, source_chat:)
      Coworkers::Chat.find_or_create_by!(coworker:, source_chat_session: source_chat, role: "mention") do |link|
        link.chat_session = ChatSession.create!(
          user: coworker.owner_user,
          repository: coworker.workspace_repository,
          title: "@#{coworker.handle} in #{source_chat.title.presence || "Chat #{source_chat.id}"}",
          hidden_at: Time.current,
          **coworker.chat_configuration
        )
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def deliver!(link:, source_message:)
      link.with_lock do
        messages = source_messages(link, source_message)
        prompt = delivery_prompt(link:, source_message:, messages:)
        delivered = link.chat_session.messages.create!(
          role: "user",
          content: {
            "text" => prompt,
            "source" => "coworker_mention",
            "coworker_mention" => {
              "source_chat_session_id" => link.source_chat_session_id,
              "source_message_id" => source_message.id,
              "hop_count" => source_message.content.to_h.dig("coworker_message", "hop_count").to_i
            }
          },
          skip_turn_trigger: false
        )
        link.update!(last_delivered_message_id: source_message.id)
        delivered
      end
    end

    def fail!(source_message:, coworker:, error:)
      return unless source_message && coworker

      claimed = source_message.with_lock do
        content = source_message.content.deep_dup
        failures = Array(content["coworker_mention_failures"]).map(&:to_i)
        next false if failures.include?(coworker.id)

        content["coworker_mention_failures"] = failures + [ coworker.id ]
        source_message.update!(content: content)
        true
      end
      return unless claimed

      source_message.chat_session.messages.create!(
        role: "system",
        content: { "text" => "@#{coworker.handle} could not finish this mention.", "source" => "coworker_mention_failure", "error" => error.class.name },
        skip_turn_trigger: true
      )
    end

    private

    def source_messages(link, source_message)
      scope = link.source_chat_session.messages.active.where("id <= ?", source_message.id).order(:id)
      scope = if link.last_delivered_message_id
        scope.where("id > ?", link.last_delivered_message_id)
      else
        scope.last(INITIAL_CONTEXT_MESSAGES)
      end
      Array(scope)
    end

    def delivery_prompt(link:, source_message:, messages:)
      sender = source_message.sender_user&.display_name || link.source_chat_session.user.display_name
      transcript = messages.map { |message| "#{message.role}: #{message.extract_text_from_content}" }.join("\n\n")
      <<~TEXT.strip
        #{sender} mentioned you in source chat ##{link.source_chat_session_id}.

        Your final assistant message will be delivered automatically to that chat as your reply. Make it self-contained. You have read-only access to that source chat while you remain on its roster; use read_chat_messages if more history is needed. Explicit chat messaging tools still work.

        New source-chat context:

        #{transcript}
      TEXT
    end
  end
end
