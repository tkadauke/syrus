module App
  class ChatTurnRetryState
    CLASSIFICATION = "chat_turn_crashed".freeze
    CLASSIFICATION_LABEL = "Chat turn crashed".freeze
    SCHEDULED_LABEL = "Retry scheduled".freeze
    EXHAUSTED_LABEL = "Auto-retry exhausted".freeze

    def self.for(chat_session, now: Time.current)
      new(chat_session, now: now).as_json
    end

    def initialize(chat_session, now:)
      @chat_session = chat_session
      @now = now
    end

    def as_json
      attempt = current_attempt
      return nil unless attempt

      {
        classification: CLASSIFICATION,
        classification_label: CLASSIFICATION_LABEL,
        retryable: retryable?(attempt),
        next_auto_retry_at: iso8601(next_auto_retry_at(attempt)),
        retry_attempt_count: attempt.attempt_number,
        retry_budget_remaining: retry_budget_remaining(attempt),
        retry_budget: retry_budget,
        auto_retry_exhausted: attempt.exhausted_at.present?,
        provider_circuit_open: false,
        retry_delayed_until: nil,
        retry_delay_reason: nil,
        state_label: state_label(attempt)
      }
    end

    private

    attr_reader :chat_session, :now

    def current_attempt
      return nil unless chat_session.turn_in_flight?

      @current_attempt ||= chat_session.turn_auto_retry_attempts
        .active
        .where(performed_at: nil)
        .order(scheduled_at: :asc, id: :asc)
        .first
    end

    def retryable?(attempt)
      attempt.exhausted_at.blank? && retry_budget_remaining(attempt).positive?
    end

    def next_auto_retry_at(attempt)
      return nil if attempt.exhausted_at.present?

      attempt.scheduled_at
    end

    def retry_budget_remaining(attempt)
      [ retry_budget - attempt.attempt_number, 0 ].max
    end

    def retry_budget
      ChatTurnAutoRetryAttempt::MAX_ATTEMPTS
    end

    def state_label(attempt)
      return EXHAUSTED_LABEL if attempt.exhausted_at.present?
      return "Retrying now" if attempt.scheduled_at <= now

      SCHEDULED_LABEL
    end

    def iso8601(value)
      value&.iso8601
    end
  end
end
