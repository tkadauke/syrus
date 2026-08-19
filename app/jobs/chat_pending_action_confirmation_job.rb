class ChatPendingActionConfirmationJob < ApplicationJob
  queue_as :control_plane

  def perform(chat_pending_action_id)
    ChatPendingAction.find(chat_pending_action_id).execute_confirmation!
  end
end
