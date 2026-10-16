class CreateChatSpendEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_spend_entries do |t|
      t.references :chat_session, null: false
      t.references :user, null: false
      t.datetime :incurred_at, null: false
      t.decimal :cost_usd, precision: 12, scale: 6, null: false
      t.string :agent_provider, null: false

      t.timestamps
    end

    unless index_exists?(:chat_spend_entries, [ :user_id, :incurred_at, :cost_usd ], name: "idx_chat_spend_entries_user_window")
      add_index :chat_spend_entries, [ :user_id, :incurred_at, :cost_usd ], name: "idx_chat_spend_entries_user_window"
    end
    unless index_exists?(:chat_spend_entries, [ :agent_provider, :incurred_at ], name: "idx_chat_spend_entries_provider_window")
      add_index :chat_spend_entries, [ :agent_provider, :incurred_at ], name: "idx_chat_spend_entries_provider_window"
    end
  end
end
