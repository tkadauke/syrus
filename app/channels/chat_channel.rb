class ChatChannel < ApplicationCable::Channel
  def self.stream_name(chat_session_id)
    "chat_resource:#{chat_session_id}"
  end

  def subscribed
    chat_session = current_user.accessible_chat_sessions.active.find_by(id: params[:chat_id])
    return reject unless chat_session

    stream_from self.class.stream_name(chat_session.id)
  end
end
