require "mcp"

module Coworkers
  class MessageCoworkerTool < MCP::Tool
    MAX_HOPS = 3

    tool_name "message_coworker"

    description "Queue a message from the current coworker to another active coworker owned by the same operator. The message is delivered to both coworkers' main chats."

    input_schema(
      properties: {
        handle: { type: "string", description: "The receiving coworker's handle, with or without @." },
        text: { type: "string", description: "The message to deliver." }
      },
      required: %w[handle text]
    )

    class << self
      def call(handle:, text:, server_context:)
        chat = server_context.fetch(:chat_session)
        sender = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat.id)&.coworker
        return Mcp::Tools.invalid("message_coworker is only available from a coworker's chat") unless sender

        normalized_handle = HandleRegistry.normalize(handle.to_s.delete_prefix("@"))
        body = text.to_s.strip
        return Mcp::Tools.invalid("handle is required") if normalized_handle.blank?
        return Mcp::Tools.invalid("text is required") if body.blank?
        return Mcp::Tools.invalid("Syrus cannot receive coworker messages") if normalized_handle == "syrus"
        return Mcp::Tools.invalid("a coworker cannot message itself") if normalized_handle == sender.handle

        receiver = Coworkers::Coworker.find_by(owner_user_id: sender.owner_user_id, handle: normalized_handle)
        return Mcp::Tools.invalid("@#{normalized_handle} is not one of this owner's coworkers") unless receiver
        return Mcp::Tools.invalid("@#{receiver.handle} is #{receiver.state} and cannot receive messages") unless receiver.state == "active"

        message_context = delivery_context(server_context[:current_message])
        return Mcp::Tools.invalid("coworker message chain reached its #{MAX_HOPS}-hop limit") if message_context.fetch("hop_count") > MAX_HOPS

        rate_limit = Coworkers::MessageRateLimiter.reserve(sender: sender, receiver: receiver)
        unless rate_limit.allowed?
          return Mcp::Tools.invalid(
            "coworker message rate limit reached for @#{sender.handle} and @#{receiver.handle}; " \
            "try again in #{rate_limit.retry_after_seconds} seconds"
          )
        end

        delivery = Coworkers::MessageDeliveryJob.perform_later(sender.id, receiver.id, body, message_context)
        return Mcp::Tools.invalid("the coworker message could not be queued") unless delivery

        Mcp::Tools.success(queued: true, from_handle: sender.handle, to_handle: receiver.handle)
      end

      private

      def delivery_context(current_message)
        incoming = current_message&.content.to_h.fetch("coworker_message", {})
        {
          "origin_turn_id" => incoming["origin_turn_id"] || current_message&.id,
          "hop_count" => incoming.fetch("hop_count", 0).to_i + 1
        }
      end
    end
  end
end
