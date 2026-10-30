require "mcp"

module Coworkers
  class ReplyInChatThreadTool < MCP::Tool
    tool_name "reply_in_chat_thread"

    description <<~DESC
      Reply within an existing cross-chat bridge thread opened by this
      coworker's owner. Plain chat text is not delivered to the other chat;
      call this tool with the thread id from the incoming message.
    DESC

    input_schema(
      properties: {
        thread_id: { type: "integer", description: "Existing ChatBridgeThread id to reply within." },
        text: { type: "string", description: "Message text to deliver to the owner's counterpart chat." }
      },
      required: %w[thread_id text]
    )

    class << self
      def call(thread_id:, text:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        coworker = Coworkers::Chat.includes(:coworker).find_by(chat_session_id: chat_session.id)&.coworker
        return Mcp::Tools.invalid("reply_in_chat_thread is only available from a coworker's chat") unless coworker

        body = text.to_s.strip
        return Mcp::Tools.invalid("text is required") if body.blank?

        thread = ChatBridgeThread.find_by(id: thread_id)
        return inaccessible unless thread_member?(thread, chat_session)
        return inaccessible unless owner_thread?(thread, chat_session, coworker)
        return Mcp::Tools.invalid("chat bridge thread #{thread.id} is closed") unless thread.open?
        return Mcp::Tools.invalid("chat bridge thread #{thread.id} reached its hop limit") if thread.at_max_hops?

        result = ChatSession::CrossChatMessage.new(thread: thread, text: body, from: chat_session).deliver!
        thread.reload
        Mcp::Tools.success(
          thread_id: thread.id,
          state: thread.state,
          hop_count: thread.hop_count,
          max_hops: thread.max_hops,
          hops_remaining: thread.hops_remaining,
          target_chat_session_id: thread.counterpart(chat_session).id,
          message_id: result.fetch(:outbound_message).id
        )
      rescue ChatSession::CrossChatMessage::ClosedThreadError => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def thread_member?(thread, chat_session)
        thread && [ thread.origin_chat_session_id, thread.target_chat_session_id ].include?(chat_session.id)
      end

      def owner_thread?(thread, chat_session, coworker)
        thread.opened_by_user_id == coworker.owner_user_id &&
          thread.counterpart(chat_session).user_id == coworker.owner_user_id
      end

      def inaccessible
        Mcp::Tools.invalid("chat bridge thread not found or not accessible")
      end
    end
  end
end
