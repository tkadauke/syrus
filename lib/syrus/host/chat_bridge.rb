module Syrus
  module Host
    # Opens and replies within the thread that links an origin chat to a
    # spawned chat. The thread record's persistence is not promised.
    module ChatBridge
      ClosedThreadError = ::ChatSession::CrossChatMessage::ClosedThreadError

      # Creates the thread and delivers the opening prompt; returns the thread.
      def self.open!(origin_chat:, target_chat:, opened_by:, prompt:)
        thread = ::ChatBridgeThread.create!(
          origin_chat_session: origin_chat, target_chat_session: target_chat, opened_by_user: opened_by
        )
        ::ChatSession::CrossChatMessage.new(thread:, text: prompt, from: origin_chat).deliver!
        thread
      end

      def self.find_thread(id) = ::ChatBridgeThread.find_by(id: id)

      # Delivers a reply from one side of the thread; raises ClosedThreadError.
      def self.reply!(thread:, text:, from:)
        ::ChatSession::CrossChatMessage.new(thread:, text:, from:).deliver!
      end
    end
  end
end
