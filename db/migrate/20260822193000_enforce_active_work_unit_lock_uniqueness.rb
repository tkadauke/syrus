class EnforceActiveWorkUnitLockUniqueness < ActiveRecord::Migration[8.1]
  class MigrationWorkUnitLock < ActiveRecord::Base
    self.table_name = "work_unit_locks"
  end

  def up
    add_column :work_unit_locks, :active_lock_key, :string, limit: 255 unless column_exists?(:work_unit_locks, :active_lock_key)
    MigrationWorkUnitLock.reset_column_information

    release_duplicate_active_locks!

    MigrationWorkUnitLock.where(released_at: nil).where(active_lock_key: nil).find_each do |lock|
      lock.update_columns(active_lock_key: lock.lock_key)
    end
    MigrationWorkUnitLock.where.not(released_at: nil).where.not(active_lock_key: nil).update_all(active_lock_key: nil)

    add_index :work_unit_locks, :active_lock_key, unique: true, name: "idx_work_unit_locks_active_key_unique", if_not_exists: true
  end

  def down
    remove_index :work_unit_locks, name: "idx_work_unit_locks_active_key_unique" if index_exists?(:work_unit_locks, :active_lock_key, name: "idx_work_unit_locks_active_key_unique")
    remove_column :work_unit_locks, :active_lock_key if column_exists?(:work_unit_locks, :active_lock_key)
  end

  private

  def release_duplicate_active_locks!
    now = Time.current
    duplicate_keys.each do |lock_key|
      ids = MigrationWorkUnitLock
        .where(lock_key: lock_key, released_at: nil)
        .order(:acquired_at, :id)
        .pluck(:id)
      keep_id, *duplicate_ids = ids
      next if keep_id.blank? || duplicate_ids.blank?

      MigrationWorkUnitLock.where(id: duplicate_ids).update_all(released_at: now, active_lock_key: nil, updated_at: now)
    end
  end

  def duplicate_keys
    MigrationWorkUnitLock
      .where(released_at: nil)
      .group(:lock_key)
      .having("COUNT(*) > 1")
      .pluck(:lock_key)
  end
end
