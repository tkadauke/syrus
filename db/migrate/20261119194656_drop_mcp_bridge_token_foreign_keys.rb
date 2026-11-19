class DropMcpBridgeTokenForeignKeys < ActiveRecord::Migration[8.1]
  # CreateMcpBridgeTokens first shipped with database constraints on its
  # references, against the no-database-foreign-keys policy, and ran on
  # deployed instances before that was caught. The migration itself no longer
  # adds them; this removes the ones it already created. Idempotent: a fresh
  # install has none to remove.
  def up
    return unless table_exists?(:mcp_bridge_tokens)

    foreign_keys(:mcp_bridge_tokens).each do |foreign_key|
      remove_foreign_key :mcp_bridge_tokens, name: foreign_key.name
    end
  end

  def down
    # Intentionally irreversible. Syrus does not use database-level foreign keys.
  end
end
