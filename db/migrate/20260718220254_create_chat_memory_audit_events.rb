class CreateChatMemoryAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_memory_audit_events, if_not_exists: true do |t|
      t.references :chat_memory, null: false, foreign_key: true, index: true
      t.string :event_type, null: false
      t.string :actor_kind, null: false
      t.references :actor_user, null: true, foreign_key: { to_table: :users }, index: true
      t.references :actor_run, null: true, foreign_key: { to_table: :runs }, index: true
      t.text :previous_content
      t.text :new_content
      t.string :previous_kind
      t.string :new_kind
      t.float :previous_confidence
      t.float :new_confidence
      t.datetime :created_at, null: false
    end
  end

  def down
    drop_table :chat_memory_audit_events, if_exists: true
  end
end
