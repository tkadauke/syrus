class AddUnsavedWorkspaceToCoworkerChats < ActiveRecord::Migration[8.1]
  def change
    add_column :coworker_chats, :unsaved_workspace_branch, :string unless column_exists?(:coworker_chats, :unsaved_workspace_branch)
    add_column :coworker_chats, :unsaved_workspace_path, :string unless column_exists?(:coworker_chats, :unsaved_workspace_path)
    add_column :coworker_chats, :unsaved_workspace_error, :text unless column_exists?(:coworker_chats, :unsaved_workspace_error)
    add_column :coworker_chats, :unsaved_workspace_failure_kind, :string unless column_exists?(:coworker_chats, :unsaved_workspace_failure_kind)
    add_column :coworker_chats, :unsaved_workspace_operation, :string unless column_exists?(:coworker_chats, :unsaved_workspace_operation)
    add_column :coworker_chats, :unsaved_workspace_first_failed_at, :datetime unless column_exists?(:coworker_chats, :unsaved_workspace_first_failed_at)
    add_column :coworker_chats, :unsaved_workspace_last_failed_at, :datetime unless column_exists?(:coworker_chats, :unsaved_workspace_last_failed_at)
    add_column :coworker_chats, :unsaved_workspace_attempt_count, :integer unless column_exists?(:coworker_chats, :unsaved_workspace_attempt_count)
    add_column :coworker_chats, :unsaved_workspace_notice_message_id, :integer unless column_exists?(:coworker_chats, :unsaved_workspace_notice_message_id)
    add_column :coworker_chats, :unsaved_workspace_retry_exhausted_at, :datetime unless column_exists?(:coworker_chats, :unsaved_workspace_retry_exhausted_at)
    add_column :coworker_chats, :unsaved_workspace_retry_scheduled_at, :datetime unless column_exists?(:coworker_chats, :unsaved_workspace_retry_scheduled_at)
    add_column :coworker_chats, :unsaved_workspace_retry_token, :string unless column_exists?(:coworker_chats, :unsaved_workspace_retry_token)
  end
end
