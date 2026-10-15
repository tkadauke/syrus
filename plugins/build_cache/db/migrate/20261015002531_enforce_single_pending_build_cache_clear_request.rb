class EnforceSinglePendingBuildCacheClearRequest < ActiveRecord::Migration[8.1]
  PENDING_UNIQUENESS_KEY = "pending".freeze

  class MigrationClearRequest < ActiveRecord::Base
    self.table_name = "build_cache_clear_requests"
  end

  def up
    add_column :build_cache_clear_requests, :pending_uniqueness_key, :string unless column_exists?(:build_cache_clear_requests, :pending_uniqueness_key)
    MigrationClearRequest.reset_column_information

    cancel_duplicate_pending_requests!
    MigrationClearRequest.where(state: "pending").update_all(pending_uniqueness_key: PENDING_UNIQUENESS_KEY)
    MigrationClearRequest.where.not(state: "pending").update_all(pending_uniqueness_key: nil)

    unless index_exists?(:build_cache_clear_requests, :pending_uniqueness_key, name: "idx_build_cache_clear_requests_one_pending")
      add_index :build_cache_clear_requests, :pending_uniqueness_key,
                unique: true,
                name: "idx_build_cache_clear_requests_one_pending"
    end
  end

  def down
    remove_index :build_cache_clear_requests, name: "idx_build_cache_clear_requests_one_pending" if index_exists?(:build_cache_clear_requests, name: "idx_build_cache_clear_requests_one_pending")
    remove_column :build_cache_clear_requests, :pending_uniqueness_key if column_exists?(:build_cache_clear_requests, :pending_uniqueness_key)
  end

  private

  def cancel_duplicate_pending_requests!
    pending_ids = MigrationClearRequest.where(state: "pending").order(created_at: :desc, id: :desc).pluck(:id)
    _keeper_id, *duplicate_ids = pending_ids
    return if duplicate_ids.empty?

    now = Time.current
    MigrationClearRequest.where(id: duplicate_ids).update_all(state: "cancelled", cancelled_at: now, updated_at: now)
  end
end
