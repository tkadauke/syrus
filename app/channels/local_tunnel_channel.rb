class LocalTunnelChannel < ApplicationCable::Channel
  def subscribed
    return reject unless Feature.local_mode_enabled?

    @session = LocalDaemonSession
      .joins(:chat_session)
      .where(chat_sessions: { user_id: current_user.id })
      .find_by(id: params[:daemon_session_id])

    return reject if @session.nil?
    return reject unless valid_auth_token?(params[:auth_token])

    @session.update!(connected_at: Time.current, last_ping_at: Time.current, disconnected_at: nil)
    stream_from "local_tunnel_#{@session.id}"

    # Deliver any tool calls that were dispatched before the daemon connected.
    flush_pending_tool_calls
  end

  def unsubscribed
    @session&.disconnect!
  end

  def ping(_data = nil)
    @session&.update!(last_ping_at: Time.current)
    transmit({ type: "pong" })
  end

  def tool_result(data)
    return unless @session

    call = @session.tool_calls.find_by(id: data["id"])
    return unless call

    if data["error"].present?
      call.update!(error: data["error"].to_s, completed_at: Time.current)
    else
      call.update!(result: data["result"], completed_at: Time.current)
    end
  end

  private

  def valid_auth_token?(token)
    token.present? && ActiveSupport::SecurityUtils.secure_compare(@session.auth_token, token)
  end

  def flush_pending_tool_calls
    @session.tool_calls.where(dispatched_at: nil).order(:created_at, :id).each do |call|
      transmit({ type: "tool_call", id: call.id, tool: call.tool_name, arguments: call.arguments })
      call.update!(dispatched_at: Time.current)
    end
  end
end
