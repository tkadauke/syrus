class CreateCoworkerWorkspaceConflicts < ActiveRecord::Migration[8.1]
  def change
    create_table :coworker_workspace_conflicts, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: true
      t.string :source_branch, null: false
      t.string :recovery_ref
      t.json :files, null: false
      t.json :versions, null: false
      t.text :detail
      t.string :state, null: false, default: "pending"
      t.integer :attempt_count, null: false, default: 0
      t.datetime :notified_at
      t.datetime :resolved_at
      t.timestamps
    end

    add_index :coworker_workspace_conflicts, [ :chat_session_id, :repository_id, :state ],
      name: "idx_coworker_workspace_conflicts_active"
  end
end
