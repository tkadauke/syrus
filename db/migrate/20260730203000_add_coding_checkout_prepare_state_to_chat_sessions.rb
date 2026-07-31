class AddCodingCheckoutPrepareStateToChatSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_sessions, :coding_checkout_prepare_status, :string unless column_exists?(:chat_sessions, :coding_checkout_prepare_status)
    add_column :chat_sessions, :coding_checkout_prepare_started_at, :datetime unless column_exists?(:chat_sessions, :coding_checkout_prepare_started_at)
    add_column :chat_sessions, :coding_checkout_prepare_finished_at, :datetime unless column_exists?(:chat_sessions, :coding_checkout_prepare_finished_at)
    add_column :chat_sessions, :coding_checkout_prepare_failure, :text unless column_exists?(:chat_sessions, :coding_checkout_prepare_failure)
  end
end
