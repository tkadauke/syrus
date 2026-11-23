require "forwardable"

module Syrus
  module Host
    # Enqueues an agent turn for a chat message.
    module ChatTurns
      def self.enqueue(chat_session_id, message_id)
        ::ChatTurnJob.perform_later(chat_session_id, message_id)
      end
    end
  end
end
