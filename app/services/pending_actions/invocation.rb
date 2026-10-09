module PendingActions
  # Documented duck type consumed by PendingActions::Base. ChatPendingAction is
  # one implementation; non-chat surfaces can include this role and provide the
  # same readers without creating a ChatSession-backed record.
  module Invocation
    REQUIRED_METHODS = %i[
      payload
      reason
      user
      chat_session
      repository
      update_confirmation_progress!
    ].freeze

    def self.assert_compatible!(record)
      missing = REQUIRED_METHODS.reject { |method| record.respond_to?(method) }
      return if missing.empty?

      raise ArgumentError, "pending action invocation is missing: #{missing.join(', ')}"
    end

    def update_confirmation_progress!(status, step)
      Rails.logger.info(
        "[pending_action] #{status}: #{step}"
      )
    end
  end
end
