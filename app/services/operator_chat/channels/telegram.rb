module OperatorChat
  module Channels
    class Telegram
      def self.deliver!(operator_question)
        ChatChannel::Telegram.new.deliver_question(operator_question)
      rescue ChatChannel::ConfigurationError, ChatChannel::DeliveryError => e
        raise OperatorChat::DeliveryError, e.message
      end
    end
  end
end
