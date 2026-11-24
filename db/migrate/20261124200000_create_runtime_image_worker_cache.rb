class CreateRuntimeImageWorkerCache < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_cache_entries, if_not_exists: true do |t|
      t.string :hostname, null: false, limit: 191
      t.bigint :runtime_image_id, null: false
      t.string :digest, null: false, limit: 191
      t.string :state, null: false, limit: 32, default: "present"
      t.bigint :size_bytes
      t.boolean :prefetched, null: false, default: false
      t.datetime :pulled_at
      t.datetime :last_used_at
      t.datetime :leased_until
      t.timestamps
    end
    add_index :runtime_image_cache_entries, %i[hostname runtime_image_id], unique: true, name: "idx_ri_cache_entries_host_image" unless index_exists?(:runtime_image_cache_entries, %i[hostname runtime_image_id], name: "idx_ri_cache_entries_host_image")
    add_index :runtime_image_cache_entries, %i[hostname state last_used_at], name: "idx_ri_cache_entries_lru" unless index_exists?(:runtime_image_cache_entries, %i[hostname state last_used_at], name: "idx_ri_cache_entries_lru")

    create_table :runtime_image_pull_events, if_not_exists: true do |t|
      t.string :hostname, null: false, limit: 191
      t.bigint :runtime_image_id
      t.string :digest, null: false, limit: 191
      t.string :outcome, null: false, limit: 32
      t.boolean :cache_hit, null: false, default: false
      t.boolean :prefetch, null: false, default: false
      t.integer :duration_ms
      t.string :error_class, limit: 191
      t.string :error_message, limit: 500
      t.datetime :created_at, null: false
    end
    add_index :runtime_image_pull_events, %i[hostname created_at], name: "idx_ri_pull_events_host_time" unless index_exists?(:runtime_image_pull_events, %i[hostname created_at], name: "idx_ri_pull_events_host_time")
    add_index :runtime_image_pull_events, %i[outcome created_at], name: "idx_ri_pull_events_outcome_time" unless index_exists?(:runtime_image_pull_events, %i[outcome created_at], name: "idx_ri_pull_events_outcome_time")
  end

  def down
    drop_table :runtime_image_pull_events, if_exists: true
    drop_table :runtime_image_cache_entries, if_exists: true
  end
end
