class LocalTunnelChannel < ApplicationCable::Channel
  HEARTBEAT_INTERVAL = 15.seconds
  # Allow one missed pong before treating the connection as lost.
  HEARTBEAT_TIMEOUT  = 45.seconds
  DISPATCH_POLL      = 0.5.seconds

  def subscribed
    return reject unless Feature.local_mode_enabled?

    @daemon_session = find_daemon_session
    return reject unless @daemon_session

    stream_from "local_daemon_session_#{@daemon_session.id}_tool_calls"

    start_heartbeat_thread
    start_dispatch_thread
  end

  def unsubscribed
    stop_threads
    @daemon_session&.mark_disconnected!
  end

  # Messages from the daemon CLI:
  #   { "type" => "connect",  "repo" => "...", "branch" => "..." }
  #   { "type" => "pong" }
  #   { "type" => "tool_result", "tool_use_id" => "...", "content" => [...] }
  def receive(data)
    case data["type"]
    when "connect"
      handle_connect(data)
    when "pong"
      @daemon_session.record_heartbeat!
    when "tool_result"
      handle_tool_result(data)
    end
  end

  # Called by Action Cable when a broadcast arrives on the
  # "local_daemon_session_N_tool_calls" stream (triggered by LocalToolCall
  # after_create_commit). Dispatches the tool call to the daemon immediately
  # without waiting for the next dispatch-thread poll cycle.
  def receive_from_subscription(message)
    return unless message["type"] == "dispatch"

    tool_call = LocalToolCall.find_by(id: message["tool_call_id"])
    return unless tool_call&.state == "pending"

    dispatch_tool_call(tool_call)
  end

  private

  def find_daemon_session
    chat_session_id = params[:chat_session_id]
    tunnel_token    = params[:tunnel_token]

    return unless chat_session_id.present? && tunnel_token.present?

    session = LocalDaemonSession.connected.find_by(
      chat_session_id: chat_session_id,
      auth_token: tunnel_token
    )
    return unless session
    return unless session.user_id == current_user.id

    session
  end

  def handle_connect(data)
    repo   = data["repo"].to_s.strip
    branch = data["branch"].to_s.strip
    @daemon_session.mark_connected!(repo: repo, branch: branch)
    transmit({ type: "connected" })
    drain_queued_tool_calls
  end

  def handle_tool_result(data)
    tool_use_id = data["tool_use_id"].to_s
    content     = data["content"]

    tool_call = LocalToolCall.find_by(
      local_daemon_session_id: @daemon_session.id,
      tool_use_id: tool_use_id
    )
    return unless tool_call

    if content
      tool_call.complete!(result: content)
    else
      tool_call.fail!(error: "daemon returned empty content")
    end
  end

  def dispatch_tool_call(tool_call)
    tool_call.dispatch!
    transmit({
      type:        "tool_call",
      tool_use_id: tool_call.tool_use_id,
      tool:        tool_call.tool_name,
      input:       tool_call.tool_input
    })
  rescue => e
    tool_call.fail!(error: e.message)
  end

  def drain_queued_tool_calls
    @daemon_session.pending_tool_calls.each do |tool_call|
      dispatch_tool_call(tool_call)
    end
  end

  def start_heartbeat_thread
    @heartbeat_thread = Thread.new do
      loop do
        sleep HEARTBEAT_INTERVAL
        transmit({ type: "ping" })
        check_heartbeat_timeout
      rescue => e
        Rails.logger.error("LocalTunnelChannel heartbeat error: #{e.message}")
        break
      end
    end
  end

  def check_heartbeat_timeout
    @daemon_session.reload
    return unless @daemon_session.heartbeat_stale?

    @daemon_session.mark_disconnected!
    transmit({ type: "disconnected", reason: "heartbeat_timeout" })
  end

  def start_dispatch_thread
    @dispatch_thread = Thread.new do
      loop do
        sleep DISPATCH_POLL
        drain_queued_tool_calls
      rescue => e
        Rails.logger.error("LocalTunnelChannel dispatch error: #{e.message}")
        break
      end
    end
  end

  def stop_threads
    @heartbeat_thread&.kill
    @dispatch_thread&.kill
  end
end
