class GeneralizeChatPendingActionsForAuthorization < ActiveRecord::Migration[8.1]
  def up
    change_column_null :chat_pending_actions, :chat_session_id, true
    add_reference :chat_pending_actions, :origin, polymorphic: true, null: true unless column_exists?(:chat_pending_actions, :origin_id)
    add_reference :chat_pending_actions, :subject, polymorphic: true, null: true unless column_exists?(:chat_pending_actions, :subject_id)
    add_column :chat_pending_actions, :request_kind, :string, null: false, default: "legacy_action" unless column_exists?(:chat_pending_actions, :request_kind)
    add_column :chat_pending_actions, :runtime_role, :string unless column_exists?(:chat_pending_actions, :runtime_role)
    add_column :chat_pending_actions, :deduplication_key, :string unless column_exists?(:chat_pending_actions, :deduplication_key)
    add_column :chat_pending_actions, :deduplication_active, :boolean unless column_exists?(:chat_pending_actions, :deduplication_active)
    add_column :chat_pending_actions, :purpose, :text unless column_exists?(:chat_pending_actions, :purpose)
    add_column :chat_pending_actions, :non_actionable_reason, :text unless column_exists?(:chat_pending_actions, :non_actionable_reason)
    add_column :chat_pending_actions, :non_actionable_at, :datetime unless column_exists?(:chat_pending_actions, :non_actionable_at)
    add_column :chat_pending_actions, :delivery_state, :string unless column_exists?(:chat_pending_actions, :delivery_state)
    add_column :chat_pending_actions, :delivery_attempts, :integer, null: false, default: 0 unless column_exists?(:chat_pending_actions, :delivery_attempts)
    add_column :chat_pending_actions, :delivered_at, :datetime unless column_exists?(:chat_pending_actions, :delivered_at)
    add_column :chat_pending_actions, :last_delivery_error, :text unless column_exists?(:chat_pending_actions, :last_delivery_error)
    add_column :chat_pending_actions, :delivery_metadata, :json unless column_exists?(:chat_pending_actions, :delivery_metadata)

    add_index :chat_pending_actions, [ :deduplication_key, :deduplication_active ], unique: true, name: "idx_pending_actions_active_deduplication" unless index_exists?(:chat_pending_actions, name: "idx_pending_actions_active_deduplication")
    add_index :chat_pending_actions, [ :state, :non_actionable_at ], name: "idx_pending_actions_actionability" unless index_exists?(:chat_pending_actions, name: "idx_pending_actions_actionability")
    add_index :chat_pending_actions, [ :delivery_state, :created_at ], name: "idx_pending_actions_delivery" unless index_exists?(:chat_pending_actions, name: "idx_pending_actions_delivery")

    execute <<~SQL.squish
      UPDATE chat_pending_actions
      SET origin_type = 'ChatSession', origin_id = chat_session_id, delivery_metadata = '{}'
      WHERE chat_session_id IS NOT NULL
    SQL
    execute "UPDATE chat_pending_actions SET delivery_metadata = '{}' WHERE delivery_metadata IS NULL"
    change_column_null :chat_pending_actions, :delivery_metadata, false
  end

  def down
    execute "DELETE FROM chat_pending_actions WHERE chat_session_id IS NULL"
    remove_index :chat_pending_actions, name: "idx_pending_actions_delivery" if index_exists?(:chat_pending_actions, name: "idx_pending_actions_delivery")
    remove_index :chat_pending_actions, name: "idx_pending_actions_actionability" if index_exists?(:chat_pending_actions, name: "idx_pending_actions_actionability")
    remove_index :chat_pending_actions, name: "idx_pending_actions_active_deduplication" if index_exists?(:chat_pending_actions, name: "idx_pending_actions_active_deduplication")
    remove_index :chat_pending_actions, :deduplication_key if index_exists?(:chat_pending_actions, :deduplication_key)
    %i[delivery_metadata last_delivery_error delivered_at delivery_attempts delivery_state non_actionable_at non_actionable_reason purpose deduplication_active deduplication_key request_kind runtime_role].each do |column|
      remove_column :chat_pending_actions, column if column_exists?(:chat_pending_actions, column)
    end
    remove_reference :chat_pending_actions, :subject, polymorphic: true if column_exists?(:chat_pending_actions, :subject_id)
    remove_reference :chat_pending_actions, :origin, polymorphic: true if column_exists?(:chat_pending_actions, :origin_id)
    change_column_null :chat_pending_actions, :chat_session_id, false
  end
end
