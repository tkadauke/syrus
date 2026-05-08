class AddAgentProviderSupport < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :agent_provider, :string, default: "claude", null: false
    add_column :users, :codex_api_key, :string

    add_column :workflows, :agent_provider, :string, default: "claude", null: false
    add_column :runs, :agent_provider, :string, default: "claude", null: false
    add_column :claude_sessions, :provider, :string, default: "claude", null: false
  end
end
