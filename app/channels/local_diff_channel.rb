class LocalDiffChannel < ApplicationCable::Channel
  def subscribed
    return reject unless Feature.local_mode_enabled?

    stream_from "local_diff:#{current_user.id}"
    request_diff("head")
  end

  def receive(data)
    mode = data["mode"] == "staged" ? "staged" : "head"
    request_diff(mode)
  end

  private

  def request_diff(mode)
    session = LocalTunnelSession.connected.find_by(user: current_user)
    unless session
      transmit({ type: "diff_result", diff: nil, mode: mode, error: "not_connected" })
      return
    end

    tool = mode == "staged" ? "git_diff_staged" : "git_diff"
    call_id = "diff:#{mode}:#{SecureRandom.uuid}"

    ActionCable.server.broadcast(
      "local_tunnel:#{current_user.id}",
      { type: "tool_call", call_id: call_id, tool: tool, params: {} }
    )
  end
end
