module ChatSessions
  class Creator
    Result = Data.define(:chat_session, :user_message, :turn_triggered)
    CHAT_TURN_ENQUEUE_RETRY_DELAYS = [ 0.05, 0.2 ].freeze

    class << self
      def enqueue_turn(chat_session, user_message)
        retry_delays = CHAT_TURN_ENQUEUE_RETRY_DELAYS.dup

        begin
          ChatTurnJob.perform_later(chat_session.id, user_message.id)
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
          raise unless transient_enqueue_error?(e) && retry_delays.any?

          delay = retry_delays.shift
          Rails.logger.warn("Retrying ChatTurnJob enqueue after transient database lock: #{e.class}: #{e.message}")
          sleep(delay) if delay.positive?
          retry
        end
      end

      private

      def transient_enqueue_error?(error)
        error_chain(error).any? do |candidate|
          candidate.is_a?(ActiveRecord::LockWaitTimeout) ||
            candidate.is_a?(ActiveRecord::Deadlocked) ||
            candidate.is_a?(ActiveRecord::StatementTimeout) ||
            candidate.class.name == "SQLite3::BusyException" ||
            candidate.message.match?(/SQLite3::BusyException|database is locked|LockWaitTimeout|Deadlocked|StatementTimeout/i)
        end
      end

      def error_chain(error)
        chain = []
        while error && !chain.include?(error)
          chain << error
          error = error.cause
        end
        chain
      end
    end

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
      self.class.enqueue_turn(result.chat_session, result.user_message) if result.turn_triggered
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
