class LocalDaemonSession < ApplicationRecord
  PING_TIMEOUT = 45.seconds
  CALL_POLL_INTERVAL = 0.5.seconds
  CALL_TIMEOUT = 120.seconds

  belongs_to :chat_session
  belongs_to :user
  has_many :tool_calls, class_name: "LocalToolCall", dependent: :destroy

  def connected?
    return false if connected_at.nil?
    return false if disconnected_at.present?

    last_ping_at.nil? || last_ping_at > PING_TIMEOUT.ago
  end

  def disconnect!
    update!(disconnected_at: Time.current)
  end

  def dispatch_tool_call!(tool_name, arguments)
    call = tool_calls.create!(tool_name: tool_name, arguments: arguments)
    ActionCable.server.broadcast(
      "local_tunnel_#{id}",
      { type: "tool_call", id: call.id, tool: tool_name, arguments: arguments }
    )
    call.update!(dispatched_at: Time.current)
    call
  end
end
