class AddSessionIdIndexToProviderSessions < ActiveRecord::Migration[8.1]
  def change
    add_index :provider_sessions,
      :session_id,
      name: "index_provider_sessions_on_session_id",
      if_not_exists: true
  end
end
