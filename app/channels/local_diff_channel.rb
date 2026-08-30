class LocalDiffChannel < ApplicationCable::Channel
  def subscribed
    return reject unless Feature.local_mode_enabled?

    @chat_session = find_chat_session
    return reject unless @chat_session

    stream_from "local_diff:#{current_user.id}:#{@chat_session.id}"
    request_diff("head")
  end

  def receive(data)
    mode = data["mode"] == "staged" ? "staged" : "head"
    request_diff(mode)
  end

  private

  def find_chat_session
    chat_id = params[:chat_id]
    return unless chat_id.present?

    current_user.chat_sessions.find_by(id: chat_id)
  end

  def request_diff(mode)
    session = @chat_session.local_daemon_session
    unless session&.connected?
      transmit({ type: "diff_result", diff: nil, mode: mode, error: "not_connected" })
      return
    end

    tool = mode == "staged" ? "git_diff_staged" : "git_diff"
    response = Mcp::Tools::LocalToolDispatch.call(tool, {}, chat_session: @chat_session)
    result = local_tool_result(response)

    if result[:error]
      transmit({ type: "diff_result", diff: nil, mode: mode, error: result[:error] })
    else
      transmit({ type: "diff_result", diff: result[:diff].to_s, mode: mode, error: nil })
    end
  rescue LocalToolCall::TimedOut
    transmit({ type: "diff_result", diff: nil, mode: mode, error: "timeout" })
  rescue => e
    Rails.logger.warn("LocalDiffChannel failed to request #{mode} diff for chat #{@chat_session&.id}: #{e.class}: #{e.message}")
    transmit({ type: "diff_result", diff: nil, mode: mode, error: "failed" })
  end

  def local_tool_result(response)
    content = response.content.first
    text = content[:text] || content["text"]

    return { error: text.to_s } if response.respond_to?(:error?) && response.error?

    payload = JSON.parse(text.to_s)
    payload = payload.with_indifferent_access if payload.respond_to?(:with_indifferent_access)
    { diff: payload[:diff] || "" }
  rescue JSON::ParserError
    { error: "invalid_response" }
  end
end
