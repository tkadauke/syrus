require "forwardable"

module Syrus
  module Host
    # Delivers queued chat messages and names the metadata key carrying the
    # internal role of a queued message.
    module ChatDelivery
      def self.internal_role_key = ::ChatQueuedMessage::INTERNAL_ROLE_KEY

      def self.deliver_next_if_idle!(chat_session)
        ::ChatQueuedMessagePromoter.deliver_one_if_idle!(chat_session)
      end
    end
  end
end
