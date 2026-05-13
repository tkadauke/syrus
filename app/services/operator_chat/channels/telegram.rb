module OperatorChat
  module Channels
    class Telegram
      def self.deliver!(_operator_question)
        raise OperatorChat::DeliveryError, "Telegram operator chat is not configured"
      end
    end
  end
end
