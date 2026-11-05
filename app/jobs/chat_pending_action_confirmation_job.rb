class ChatPendingActionConfirmationJob < ApplicationJob
  queue_as :control_plane

  def perform(chat_pending_action_id)
    pending_action = ChatPendingAction
      .includes(:chat_session, :user, :subject, authorization_items: :authorized_invocation)
      .find(chat_pending_action_id)
    if pending_action.origin_type == "ChatSession" && pending_action.origin_id == pending_action.chat_session_id
      pending_action.association(:origin).target = pending_action.chat_session
    end
    pending_action.execute_confirmation!
  end
end
