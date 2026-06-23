class CreateChatMemories < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_memories, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :scope, null: false
      t.bigint :scope_id
      t.text :content, null: false
      t.boolean :published, null: false, default: false
      t.binary :embedding
      t.timestamps
    end

    unless index_exists?(:chat_memories, [ :user_id, :scope, :scope_id ])
      add_index :chat_memories, [ :user_id, :scope, :scope_id ]
    end

    unless index_exists?(:chat_memories, [ :scope_id, :published, :scope ])
      add_index :chat_memories, [ :scope_id, :published, :scope ]
    end
  end
end
