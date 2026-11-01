class CreatePendingActionOccurrences < ActiveRecord::Migration[8.1]
  def change
    create_table :pending_action_occurrences do |t|
      t.references :chat_pending_action, null: false, foreign_key: true
      t.references :origin, polymorphic: true, null: false
      t.json :metadata, null: false

      t.timestamps
    end

    add_index :pending_action_occurrences,
      [ :chat_pending_action_id, :origin_type, :origin_id ],
      unique: true,
      name: "idx_pending_action_occurrences_unique_origin"
    add_index :pending_action_occurrences,
      [ :origin_type, :origin_id, :created_at ],
      name: "idx_pending_action_occurrences_origin_time"
  end
end
