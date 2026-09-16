require "rails_helper"
require Rails.root.join("db/migrate/20260916130128_add_workspace_storage_key_to_chat_sessions")

RSpec.describe AddWorkspaceStorageKeyToChatSessions, :ci_only do
  let(:connection) { ActiveRecord::Base.connection }
  let(:migration) { described_class.new }

  after do
    migration.up
    ChatSession.reset_column_information
  end

  it "adds a nullable workspace_storage_key column and is idempotent" do
    migration.down
    expect(connection.column_exists?(:chat_sessions, :workspace_storage_key)).to be(false)

    migration.up
    migration.up
    ChatSession.reset_column_information

    column = connection.columns(:chat_sessions).find { |c| c.name == "workspace_storage_key" }
    expect(column).to be_present
    expect(column.null).to be(true)
  end
end
