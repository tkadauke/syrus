require "mcp"

module Mcp::Tools
  class SendChatMessageTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "send_chat_message"

    description <<~DESC
      Send a message to another one of this operator's chat sessions, waking
      its turn. Supply target_chat_session_id to open a new bridge thread
      (only valid when the operator's own message in this chat is what
      triggered the current turn), or thread_id to reply within an
      already-open thread from either side. Exchanges are capped at the
      thread's max_hops and auto-close once the cap is reached.
    DESC

    input_schema(
      properties: {
        text: { type: "string", description: "Message text to deliver." },
        target_chat_session_id: { type: "integer", description: "Chat session id to open a new bridge thread to. Required unless thread_id is given." },
        thread_id: { type: "integer", description: "Existing open ChatBridgeThread id to reply within. Omit to open a new thread to target_chat_session_id instead." },
        max_hops: { type: "integer", description: "Maximum hop count for a newly opened thread. Defaults to #{ChatBridgeThread::DEFAULT_MAX_HOPS}." }
      },
      required: %w[text]
    )

    class << self
      def call(server_context:, text:, target_chat_session_id: nil, thread_id: nil, max_hops: nil)
        chat_session = server_context.fetch(:chat_session)
        text = text.to_s.strip
        return Mcp::Tools.invalid("text is required") if text.blank?
        return Mcp::Tools.invalid("provide exactly one of thread_id or target_chat_session_id") if
          thread_id.present? == target_chat_session_id.present?

        if thread_id.present?
          thread = find_reply_thread!(thread_id, chat_session)
        else
          unless operator_triggered_turn?(server_context)
            return Mcp::Tools.invalid("a new bridge thread can only be opened directly from the operator's own message")
          end

          target = find_chat_session!(target_chat_session_id)
          return Mcp::Tools.invalid("cannot open a bridge thread to the same chat") if target.id == chat_session.id

          thread = ChatBridgeThread.new(origin_chat_session: chat_session, target_chat_session: target, opened_by_user: current_user)
          thread.max_hops = max_hops if max_hops.present?
        end

        result = nil
        ApplicationRecord.transaction do
          thread.save! if thread.new_record?
          result = ChatSession::CrossChatMessage.new(thread: thread, text: text, from: chat_session).deliver!
        end

        success_payload(thread.reload, chat_session, result)
      rescue ChatSession::CrossChatMessage::ClosedThreadError => e
        Mcp::Tools.invalid(e.message)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def find_reply_thread!(thread_id, chat_session)
        thread = ChatBridgeThread.find_by(id: thread_id)
        member = thread && (thread.origin_chat_session_id == chat_session.id || thread.target_chat_session_id == chat_session.id)
        raise AuthorizationSupport::AuthorizationError, "chat bridge thread not found or not accessible" unless member

        thread
      end

      # The tool only runs mid-turn, so this is normally guaranteed -- but an
      # automated/system-originated turn (e.g. a wakeup-fired turn) must not
      # be able to open a brand-new bridge thread on its own initiative. Only
      # a message the operator actually typed lacks a "requested_by" marker.
      def operator_triggered_turn?(server_context)
        message = server_context[:current_message]
        return false unless message.is_a?(ChatMessage)
        return false unless message.role == "user"

        message.content.to_h["requested_by"].blank?
      end

      def success_payload(thread, chat_session, result)
        to_chat_session = thread.counterpart(chat_session)

        Mcp::Tools.success(
          thread_id: thread.id,
          state: thread.state,
          hop_count: thread.hop_count,
          max_hops: thread.max_hops,
          hops_remaining: thread.hops_remaining,
          target_chat_session_id: to_chat_session.id,
          message_id: result.fetch(:outbound_message).id
        )
      end
    end
  end
end
