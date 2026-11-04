class AddUnsavedWorkspaceToCoworkerChats < ActiveRecord::Migration[8.1]
  COLUMNS = {
    unsaved_workspace_branch: :string, unsaved_workspace_path: :string, unsaved_workspace_error: :text,
    unsaved_workspace_failure_kind: :string, unsaved_workspace_operation: :string,
    unsaved_workspace_first_failed_at: :datetime, unsaved_workspace_last_failed_at: :datetime,
    unsaved_workspace_attempt_count: :integer, unsaved_workspace_notice_message_id: :bigint,
    unsaved_workspace_retry_exhausted_at: :datetime, unsaved_workspace_retry_scheduled_at: :datetime,
    unsaved_workspace_retry_token: :string
  }.freeze

  def up
    COLUMNS.each { |name, type| add_column(:coworker_chats, name, type) unless column_exists?(:coworker_chats, name) }
    add_index :coworker_chats, :unsaved_workspace_notice_message_id unless index_exists?(:coworker_chats, :unsaved_workspace_notice_message_id)
  end

  def down
    COLUMNS.each_key { |name| remove_column(:coworker_chats, name) if column_exists?(:coworker_chats, name) }
  end
end
