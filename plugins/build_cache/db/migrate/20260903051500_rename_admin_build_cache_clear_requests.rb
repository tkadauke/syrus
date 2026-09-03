class RenameAdminBuildCacheClearRequests < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:admin_build_cache_clear_requests)
    return if table_exists?(:build_cache_clear_requests)

    rename_table :admin_build_cache_clear_requests, :build_cache_clear_requests
  end

  def down
    return unless table_exists?(:build_cache_clear_requests)
    return if table_exists?(:admin_build_cache_clear_requests)

    rename_table :build_cache_clear_requests, :admin_build_cache_clear_requests
  end
end
