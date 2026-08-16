class AddResumableUpdatedAtIndexToProviderSessions < ActiveRecord::Migration[8.1]
  INDEX_NAME = "index_provider_sessions_on_resumable_type_updated_at"

  # ProviderSession.prunable filters `resumable_type = "Run"` and
  # `provider_sessions.updated_at < ?`, but the only date index was on
  # created_at. Rows here are small in count and enormous in bytes (~375KB of
  # transcript each), so without an index the prune had to drag the whole
  # tablespace through the buffer pool just to decide what was expired — one
  # production DELETE was measured running 1,952 seconds, holding row locks
  # for the duration.
  #
  # resumable_id trails the range column so the index also covers the join to
  # runs: candidate rows can be matched and joined straight from the index,
  # and the wide row bodies are only touched for records actually deleted.
  def up
    return if index_exists?(:provider_sessions, [ :resumable_type, :updated_at, :resumable_id ], name: INDEX_NAME)

    add_index :provider_sessions,
              [ :resumable_type, :updated_at, :resumable_id ],
              name: INDEX_NAME
  end

  def down
    return unless index_exists?(:provider_sessions, [ :resumable_type, :updated_at, :resumable_id ], name: INDEX_NAME)

    remove_index :provider_sessions, name: INDEX_NAME
  end
end
