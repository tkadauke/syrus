require "mcp"

module Coworkers
  class MessageCoworkerTool < MCP::Tool
    MAX_HOPS = Coworkers::MessageDispatcher::MAX_HOPS

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

        current_message = server_context[:current_message]
        current_message_id = current_message.id if current_message.respond_to?(:id)
        return Mcp::Tools.invalid("coworker messages require a persisted current turn") unless current_message_id.present?

        message_context = delivery_context(current_message)
        result = Coworkers::MessageDispatcher.call(sender: sender, receiver: receiver, text: body, delivery_context: message_context)
        return Mcp::Tools.invalid(result.error) unless result.delivered?

        Mcp::Tools.success(queued: true, from_handle: sender.handle, to_handle: receiver.handle)
      end

      private

      def delivery_context(current_message)
        incoming = current_message.content.to_h.fetch("coworker_message", {})
        {
          "origin_turn_id" => incoming["origin_turn_id"] || current_message.id,
          "hop_count" => incoming.fetch("hop_count", 0).to_i + 1
        }
      end
    end
  end
end
