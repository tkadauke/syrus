class CreatePendingActionOccurrences < ActiveRecord::Migration[8.1]
  def up
    create_table :pending_action_occurrences, if_not_exists: true do |t|
      t.references :chat_pending_action, null: false, foreign_key: false, index: false
      t.references :origin, polymorphic: true, null: false
      t.json :metadata, null: false

      t.timestamps
    end

    unless index_exists?(:pending_action_occurrences, name: "idx_pending_action_occurrences_unique_origin")
      add_index :pending_action_occurrences,
        [ :chat_pending_action_id, :origin_type, :origin_id ],
        unique: true,
        name: "idx_pending_action_occurrences_unique_origin"
    end
    unless index_exists?(:pending_action_occurrences, name: "idx_pending_action_occurrences_origin_time")
      add_index :pending_action_occurrences,
        [ :origin_type, :origin_id, :created_at ],
        name: "idx_pending_action_occurrences_origin_time"
    end
  end

  def down
    drop_table :pending_action_occurrences if table_exists?(:pending_action_occurrences)
  end
end
