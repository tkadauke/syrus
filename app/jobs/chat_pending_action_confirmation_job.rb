class ChatPendingActionConfirmationJob < ApplicationJob
  # Its own lane: a confirmation is an operator waiting on a spinner, and it
  # must not queue behind control-plane sweeps (see config/queue.yml).
  queue_as :operator_actions

  def perform(chat_pending_action_id)
    pending_action = ChatPendingAction
      .includes(:chat_session, :user, :subject)
      .find(chat_pending_action_id)
    if pending_action.origin_type == "ChatSession" && pending_action.origin_id == pending_action.chat_session_id
      pending_action.association(:origin).target = pending_action.chat_session
    end
    pending_action.execute_confirmation!
  end
end
