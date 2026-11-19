require "rails_helper"
require Rails.root.join("db/migrate/20261119194656_drop_mcp_bridge_token_foreign_keys")

# CreateMcpBridgeTokens first created database-level foreign keys, against the
# policy; deployed instances still carry them.
RSpec.describe DropMcpBridgeTokenForeignKeys, :ci_only do
  self.use_transactional_tests = false

  let(:connection) { ActiveRecord::Base.connection }

  after do
    connection.foreign_keys(:mcp_bridge_tokens).each { |key| connection.remove_foreign_key(:mcp_bridge_tokens, name: key.name) }
  end

  it "removes the foreign keys an instance already has, and is safe to run again" do
    connection.add_foreign_key(:mcp_bridge_tokens, :users)
    connection.add_foreign_key(:mcp_bridge_tokens, :chat_sessions)

    described_class.new.up

    expect(connection.foreign_keys(:mcp_bridge_tokens)).to be_empty
    expect { described_class.new.up }.not_to raise_error
  end
end
