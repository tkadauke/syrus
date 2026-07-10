class LocalTunnelChannel < ApplicationCable::Channel
  def subscribed
    return reject unless Feature.local_mode_enabled?

    stream_from "local_tunnel:#{current_user.id}"
  end

  def unsubscribed
    session = LocalTunnelSession.connected.find_by(user: current_user)
    session&.pause!
  end

  def receive(data)
    case data["type"]
    when "register"
      handle_register(data)
    when "tool_result"
      handle_tool_result(data)
    when "graceful_disconnect"
      handle_graceful_disconnect
    end
  end

  private

  def handle_register(data)
    repo_slug = data["repo_slug"].to_s.strip
    branch = data["branch"].to_s.strip

    session = LocalTunnelSession.active.find_by(user: current_user)
    if session
      session.reconnect!(repo_slug: repo_slug, branch: branch)
    else
      session = LocalTunnelSession.create!(
        user: current_user,
        repo_slug: repo_slug,
        branch: branch,
        status: "connected",
        connected_at: Time.current
      )
    end

    transmit({ type: "registered", tunnel_session_id: session.id, chat_session_id: session.chat_session_id })
  end

  def handle_tool_result(data)
    call_id = data["call_id"]
    return unless call_id.present?

    ActionCable.server.broadcast(
      "local_tunnel_result:#{current_user.id}:#{call_id}",
      { type: "tool_result", call_id: call_id, result: data["result"] }
    )
  end

  def handle_graceful_disconnect
    session = LocalTunnelSession.connected.find_by(user: current_user)
    session&.disconnect!
    transmit({ type: "disconnected" })
  end
end
