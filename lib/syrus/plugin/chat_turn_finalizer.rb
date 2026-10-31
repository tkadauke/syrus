module Syrus
  module Plugin
    # Marker interface for plugin-owned work that must run after an agent turn
    # but before the chat releases its serialization lock.
    #
    # Providers expose:
    #
    #   .after_chat_turn(chat_session:, user_message:, turn_succeeded:) => void
    #
    # Failures are surfaced in the chat while the local workspace is retained.
    module ChatTurnFinalizer
      def self.included(base) = base.extend(self)
    end
  end
end
