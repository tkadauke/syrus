class LocalTunnelChannel < ApplicationCable::Channel
  HEARTBEAT_INTERVAL = 15.seconds
  # Allow one missed pong before treating the connection as lost.
  HEARTBEAT_TIMEOUT  = 45.seconds
  DISPATCH_POLL      = 0.5.seconds
  THREAD_ERROR_BACKOFF = 1.second

  def subscribed
    return reject unless Feature.local_mode_enabled?

    @daemon_session = find_daemon_session
    return reject unless @daemon_session
    @connection_id = SecureRandom.uuid

    stream_from "local_daemon_session_#{@daemon_session.id}_tool_calls"

    start_heartbeat_thread
    start_dispatch_thread
  end

  def unsubscribed
    stop_threads
    @daemon_session&.mark_disconnected!(connection_id: @connection_id)
  end

  # Messages from the daemon CLI:
  #   { "type" => "connect",  "repo" => "...", "branch" => "..." }
  #   { "type" => "pong" }
  #   { "type" => "tool_result", "tool_use_id" => "...", "content" => [...] }
  #
  # Messages transmitted to the daemon CLI (see #transmit calls below):
  #   { type: "connected" }
  #   { type: "tool_call", tool_use_id:, tool:, input: }
  #   { type: "cancel_tool_call", tool_use_id: }  -- the chat shell-command cancellation feature `!` command cancel
  #   { type: "ping" }
  #   { type: "disconnected", reason: }
  def receive(data)
    case data["type"]
    when "connect"
      handle_connect(data)
    when "pong"
      @daemon_session.record_heartbeat! if current_connection?
    when "tool_result"
      handle_tool_result(data)
    end
  end

  # Called by Action Cable when a broadcast arrives on the
  # "local_daemon_session_N_tool_calls" stream. "dispatch" (triggered by
  # LocalToolCall's after_create_commit) sends a pending call to the daemon
  # immediately without waiting for the next dispatch-thread poll cycle.
  # "cancel" (triggered by LocalToolCall#request_cancel!, the chat shell-command cancellation feature's `!`
  # command cancel control) asks the daemon to interrupt a call already in
  # flight.
  def receive_from_subscription(message)
    case message["type"]
    when "dispatch"
      handle_dispatch_broadcast(message)
    when "cancel"
      handle_cancel_broadcast(message)
    end
  end

  private

  def find_daemon_session
    chat_session_id = params[:chat_session_id]
    tunnel_token    = params[:tunnel_token]

    return unless chat_session_id.present? && tunnel_token.present?

    session = LocalDaemonSession.find_by(
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
    @daemon_session.mark_connected!(repo: repo, branch: branch, connection_id: @connection_id)
    transmit({ type: "connected" })
    drain_queued_tool_calls
  end

  def handle_tool_result(data)
    return unless current_connection?

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
    @daemon_session.with_lock do
      return unless @daemon_session.current_connection?(@connection_id)
      return unless tool_call.dispatch!

      transmit({
        type:        "tool_call",
        tool_use_id: tool_call.tool_use_id,
        tool:        tool_call.tool_name,
        input:       tool_call.tool_input
      })
    end
  rescue => e
    tool_call.fail!(error: e.message)
  end

  def handle_dispatch_broadcast(message)
    tool_call = LocalToolCall.find_by(id: message["tool_call_id"])
    return unless tool_call&.state == "pending"

    dispatch_tool_call(tool_call)
  end

  def handle_cancel_broadcast(message)
    return unless current_connection?

    tool_call = LocalToolCall.find_by(id: message["tool_call_id"])
    return unless tool_call&.state == "dispatched"

    transmit({ type: "cancel_tool_call", tool_use_id: tool_call.tool_use_id })
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
        with_rails_context do
          heartbeat_tick
        end
      rescue => e
        Rails.logger.error("LocalTunnelChannel heartbeat error: #{e.message}")
        sleep THREAD_ERROR_BACKOFF
      end
    end
  end

  def check_heartbeat_timeout
    @daemon_session.reload
    return unless current_connection?
    return unless @daemon_session.heartbeat_stale?

    @daemon_session.mark_disconnected!(connection_id: @connection_id)
    transmit({ type: "disconnected", reason: "heartbeat_timeout" })
  end

  def start_dispatch_thread
    @dispatch_thread = Thread.new do
      loop do
        sleep DISPATCH_POLL
        with_rails_context do
          dispatch_tick
        end
      rescue => e
        Rails.logger.error("LocalTunnelChannel dispatch error: #{e.message}")
        sleep THREAD_ERROR_BACKOFF
      end
    end
  end

  def with_rails_context(&block)
    Rails.application.executor.wrap do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end

  def heartbeat_tick
    return unless current_connection?

    transmit({ type: "ping" })
    check_heartbeat_timeout
  end

  def dispatch_tick
    return unless current_connection?

    drain_queued_tool_calls
  end

  def stop_threads
    @heartbeat_thread&.kill
    @dispatch_thread&.kill
  end

  def current_connection?
    @daemon_session.reload.current_connection?(@connection_id)
  end
end
