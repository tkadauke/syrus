class CreateRuntimeImageBuildOrchestration < ActiveRecord::Migration[8.1]
  def up
    create_table :runtime_image_build_requests, if_not_exists: true do |t|
      t.bigint :runtime_image_namespace_id, null: false
      t.string :state, null: false, limit: 24, default: "queued"
      t.string :platform, null: false, limit: 64
      # The tuple (namespace, source_digest, recipe_digest, platform) is hashed
      # into dedup_key. active_dedup_key mirrors it only while the request is
      # not terminal, so a unique index allows exactly one live build per tuple.
      t.string :dedup_key, null: false, limit: 64
      t.string :active_dedup_key, limit: 64
      t.string :source_kind, null: false, limit: 64
      t.string :source_ref, null: false, limit: 500
      t.string :source_digest, null: false, limit: 71
      t.json :source_manifest
      t.string :recipe_digest, null: false, limit: 71
      t.json :recipe
      t.string :requester_kind, null: false, limit: 64
      t.string :requester_ref, null: false, limit: 191
      t.integer :attempts_count, null: false, default: 0
      t.integer :max_attempts, null: false, default: 3
      t.datetime :next_attempt_at
      t.datetime :cancel_requested_at
      t.string :cancel_reason, limit: 500
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps
    end
    add_index :runtime_image_build_requests, :active_dedup_key, unique: true, name: "idx_ri_build_requests_active_dedup" unless index_exists?(:runtime_image_build_requests, :active_dedup_key, name: "idx_ri_build_requests_active_dedup")
    add_index :runtime_image_build_requests, %i[state next_attempt_at], name: "idx_ri_build_requests_state" unless index_exists?(:runtime_image_build_requests, %i[state next_attempt_at], name: "idx_ri_build_requests_state")
    add_index :runtime_image_build_requests, :dedup_key, name: "idx_ri_build_requests_dedup" unless index_exists?(:runtime_image_build_requests, :dedup_key, name: "idx_ri_build_requests_dedup")
    add_index :runtime_image_build_requests, %i[requester_kind requester_ref], name: "idx_ri_build_requests_requester" unless index_exists?(:runtime_image_build_requests, %i[requester_kind requester_ref], name: "idx_ri_build_requests_requester")
    add_index :runtime_image_build_requests, :runtime_image_namespace_id, name: "idx_ri_build_requests_namespace" unless index_exists?(:runtime_image_build_requests, :runtime_image_namespace_id, name: "idx_ri_build_requests_namespace")

    create_table :runtime_image_build_attempts, if_not_exists: true do |t|
      t.bigint :runtime_image_build_request_id, null: false
      t.integer :number, null: false
      t.string :state, null: false, limit: 24, default: "building"
      t.string :worker_hostname, limit: 191
      t.datetime :lease_expires_at
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :error_code, limit: 64
      t.string :error_message, limit: 500
      t.boolean :retryable, null: false, default: false
      t.timestamps
    end
    add_index :runtime_image_build_attempts, %i[runtime_image_build_request_id number], unique: true, name: "idx_ri_build_attempts_number" unless index_exists?(:runtime_image_build_attempts, %i[runtime_image_build_request_id number], name: "idx_ri_build_attempts_number")
    add_index :runtime_image_build_attempts, %i[state lease_expires_at], name: "idx_ri_build_attempts_lease" unless index_exists?(:runtime_image_build_attempts, %i[state lease_expires_at], name: "idx_ri_build_attempts_lease")

    create_table :runtime_image_build_results, if_not_exists: true do |t|
      t.bigint :runtime_image_build_request_id, null: false
      t.bigint :runtime_image_id
      t.string :outcome, null: false, limit: 24
      t.string :digest, limit: 71
      t.string :error_code, limit: 64
      t.string :message, limit: 500
      t.integer :attempts_used, null: false, default: 0
      t.json :details
      t.datetime :finished_at, null: false
      t.timestamps
    end
    execute "UPDATE runtime_image_build_requests SET source_manifest = '{}' WHERE source_manifest IS NULL"
    execute "UPDATE runtime_image_build_requests SET recipe = '{}' WHERE recipe IS NULL"
    execute "UPDATE runtime_image_build_results SET details = '{}' WHERE details IS NULL"
    add_index :runtime_image_build_results, :runtime_image_build_request_id, unique: true, name: "idx_ri_build_results_request" unless index_exists?(:runtime_image_build_results, :runtime_image_build_request_id, name: "idx_ri_build_results_request")
    add_index :runtime_image_build_results, :runtime_image_id, name: "idx_ri_build_results_image" unless index_exists?(:runtime_image_build_results, :runtime_image_id, name: "idx_ri_build_results_image")
  end

  def down
    drop_table :runtime_image_build_results, if_exists: true
    drop_table :runtime_image_build_attempts, if_exists: true
    drop_table :runtime_image_build_requests, if_exists: true
  end
end
