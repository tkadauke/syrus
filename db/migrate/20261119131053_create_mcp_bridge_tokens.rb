class CreateMcpBridgeTokens < ActiveRecord::Migration[8.1]
  def change
    create_table :mcp_bridge_tokens, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: false
      t.references :chat_session, null: true, foreign_key: false
      t.string :name, null: false
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
    end

    add_index :mcp_bridge_tokens, :token_digest, unique: true, if_not_exists: true
  end
end
