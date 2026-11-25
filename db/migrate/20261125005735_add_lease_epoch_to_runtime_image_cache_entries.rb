# Numbers each started-over cache lease, so a holder whose lease expired cannot
# release the lease a later acquisition started (formal/SyrusModel/CacheLease.lean).
class AddLeaseEpochToRuntimeImageCacheEntries < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:runtime_image_cache_entries, :lease_epoch)

    add_column :runtime_image_cache_entries, :lease_epoch, :integer, default: 0, null: false
  end
end
