module ChatSessions
  class Creator
    Result = Data.define(:chat_session, :user_message, :turn_triggered)

    def initialize(user:, prompt:, repository: nil, provider: nil, title: nil, content: nil, title_message_text: nil)
      @user = user
      @prompt = prompt.to_s
      @repository = repository
      @provider = provider
      @title = title.to_s.strip.presence
      @content = content || { "text" => @prompt }
      @title_message_text = title_message_text
    end

    def call
      result = create_records
      if result.chat_session.title.blank?
        ChatTitleJob.perform_later(result.chat_session.id, result.user_message.id, **title_job_options)
      end
      ChatTurnJob.perform_later(result.chat_session.id, result.user_message.id) if result.turn_triggered
      result
    end

    private

    attr_reader :user, :prompt, :repository, :provider, :title, :content, :title_message_text

    def title_job_options
      title_message_text.present? ? { message_text: title_message_text } : {}
    end

    def create_records
      chat_session = nil
      user_message = nil
      turn_triggered = false

      ApplicationRecord.transaction do
        chat_session = ChatSession.create!(
          user: user,
          repository: repository,
          title: title,
          chat_provider: provider,
          last_message_at: Time.current,
          conversation_kind: "direct"
        )
        turn_triggered = chat_session.should_trigger_agent?(prompt)
        user_message = chat_session.messages.create!(
          role: "user",
          content: content,
          sender_user_id: user.id,
          skip_turn_trigger: !turn_triggered
        )
        chat_session.pin_chat_provider!(provider)
      end

      Result.new(chat_session: chat_session, user_message: user_message, turn_triggered: turn_triggered)
    end
  end
end
