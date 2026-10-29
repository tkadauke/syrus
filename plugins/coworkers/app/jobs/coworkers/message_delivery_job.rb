module Coworkers
  class MessageDeliveryJob < ApplicationJob
    queue_as :chat

    discard_on ActiveRecord::RecordNotFound

    def perform(sender_id, receiver_id, text, delivery_context = {})
      return unless valid_delivery_context?(delivery_context)

      sender = Coworkers::Coworker.find(sender_id)
      receiver = Coworkers::Coworker.find(receiver_id)
      return unless deliverable?(sender, receiver)

      sender_chat = main_chat(sender)
      receiver_chat = main_chat(receiver)

      ApplicationRecord.transaction do
        sender_chat.messages.create!(
          role: "system",
          content: message_content(direction: "outgoing", sender: sender, receiver: receiver, text: text, delivery_context: delivery_context),
          skip_turn_trigger: true
        )
        receiver_chat.chat_queued_messages.create!(
          content: message_content(direction: "incoming", sender: sender, receiver: receiver, text: text, delivery_context: delivery_context).merge(
            ChatQueuedMessage::INTERNAL_ROLE_KEY => "user"
          )
        )
      end

      ChatQueuedMessagePromoter.deliver_one_if_idle!(receiver_chat)
    end

    private

    def valid_delivery_context?(delivery_context)
      delivery_context.is_a?(Hash) &&
        Integer(delivery_context["origin_turn_id"], exception: false)&.positive? &&
        Integer(delivery_context["hop_count"], exception: false)&.positive?
    end

    def deliverable?(sender, receiver)
      sender.owner_user_id == receiver.owner_user_id && sender.id != receiver.id &&
        sender.state == "active" && receiver.state == "active"
    end

    def main_chat(coworker)
      coworker.coworker_chats.find_by!(role: "main").chat_session
    end

    def message_content(direction:, sender:, receiver:, text:, delivery_context:)
      other = direction == "incoming" ? sender : receiver
      {
        "text" => "Message #{direction == 'incoming' ? 'from' : 'to'} @#{other.handle}\n\n#{text}",
        "source" => "coworker_message",
        "coworker_message" => {
          "direction" => direction,
          "sender_id" => sender.id,
          "sender_handle" => sender.handle,
          "receiver_id" => receiver.id,
          "receiver_handle" => receiver.handle,
          "origin_turn_id" => delivery_context["origin_turn_id"],
          "hop_count" => delivery_context.fetch("hop_count", 1)
        }
      }
    end
  end
end
