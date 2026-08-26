class AddRecentObservabilityIndexToChatScopedEvents < ActiveRecord::Migration[8.1]
  def change
    return if index_exists?(:chat_scoped_events, [ :created_at, :id ], name: "idx_chat_scoped_events_recent_observability")

    add_index :chat_scoped_events, [ :created_at, :id ], name: "idx_chat_scoped_events_recent_observability"
  end
end
