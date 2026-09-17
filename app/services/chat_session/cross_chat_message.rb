class ChatSession::CrossChatMessage
  class ClosedThreadError < StandardError; end

  def initialize(thread:, text:)
    @thread = thread
    @text = text.to_s
  end

  def deliver!
    raise ClosedThreadError, "chat bridge thread #{@thread.id} is closed" unless @thread.open?

    outbound_message = create_outbound_message!
    wakeup = create_wakeup!
    @thread.register_hop!
    post_closure_notices! if @thread.closed?

    { outbound_message: outbound_message, wakeup: wakeup, thread: @thread }
  end

  private

  attr_reader :thread, :text

  def create_outbound_message!
    thread.origin_chat_session.messages.create!(
      role: "system",
      content: {
        "text" => "Sent to chat ##{thread.target_chat_session_id}: #{text}",
        "cross_chat_bridge" => "outbound",
        "bridge_thread_id" => thread.id,
        "target_chat_session_id" => thread.target_chat_session_id
      }
    )
  end

  def create_wakeup!
    ChatWakeup.create!(
      chat_session: thread.target_chat_session,
      user: thread.target_chat_session.user,
      prompt: text,
      fire_at: Time.current,
      metadata: {
        "requested_by" => "cross_chat",
        "origin_chat_session_id" => thread.origin_chat_session_id,
        "thread_id" => thread.id
      }
    )
  end

  def post_closure_notices!
    notice = "Cross-chat thread ##{thread.id} reached its hop limit (#{thread.max_hops}) and has been closed."

    [ thread.origin_chat_session, thread.target_chat_session ].each do |chat|
      chat.messages.create!(
        role: "system",
        content: { "text" => notice, "bridge_thread_id" => thread.id }
      )
    end
  end
end
