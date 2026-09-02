class AddPendingActionConfirmedPayloadIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :chat_pending_actions,
      [ :chat_session_id, :state, :confirmed_at ],
      name: "idx_chat_pending_actions_payload_confirmed",
      if_not_exists: true
  end
end
