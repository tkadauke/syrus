module Syrus
  module Host
    module ChatTitles
      def self.enqueue(chat_id:, message_id:)
        ChatTitleJob.perform_later(chat_id, message_id)
      end
    end
  end
end
