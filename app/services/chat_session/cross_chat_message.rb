class ChatSession::CrossChatMessage
  class ClosedThreadError < StandardError; end

  # `from:` lets either side of an open thread reply -- the first hop always
  # sends from the origin chat, but a reply from the target chat back to the
  # origin must be delivered in the opposite direction. Defaults to the
  # origin chat so existing single-direction callers are unaffected.
  def initialize(thread:, text:, from: nil)
    @thread = thread
    @text = text.to_s
    @from = from || thread.origin_chat_session
  end

  def deliver!
    raise ClosedThreadError, "chat bridge thread #{@thread.id} is closed" unless @thread.open?

    outbound_message = nil
    wakeup = nil
    ApplicationRecord.transaction do
      outbound_message = create_outbound_message!
      wakeup = create_wakeup!
      @thread.register_hop!
      post_closure_notices! if @thread.closed?
    end

    { outbound_message: outbound_message, wakeup: wakeup, thread: @thread }
  end

  private

  attr_reader :thread, :text, :from

  def to
    thread.counterpart(from)
  end

  def create_outbound_message!
    from.messages.create!(
      role: "system",
      content: {
        "text" => "Sent to chat ##{to.id}: #{text}",
        "cross_chat_bridge" => "outbound",
        "bridge_thread_id" => thread.id,
        "target_chat_session_id" => to.id
      }
    )
  end

  def create_wakeup!
    ChatWakeup.create!(
      chat_session: to,
      user: to.user,
      prompt: text,
      fire_at: Time.current,
      metadata: {
        "requested_by" => "cross_chat",
        "origin_chat_session_id" => from.id,
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
