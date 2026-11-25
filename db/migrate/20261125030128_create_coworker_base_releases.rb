class CreateCoworkerBaseReleases < ActiveRecord::Migration[8.1]
  def up
    create_table :coworker_base_releases, if_not_exists: true do |t|
      t.bigint :runtime_image_id, null: false
      t.string :platform, null: false, limit: 64
      t.integer :generation, null: false
      t.integer :runtime_abi, null: false
      t.integer :compat_min, null: false
      t.integer :compat_max, null: false
      t.string :status, null: false, limit: 32, default: "candidate"
      # Holds the platform while the release is active; the unique index makes
      # "at most one active base per platform" a database guarantee.
      t.string :active_key, limit: 64
      t.datetime :promoted_at
      t.string :promoted_by, limit: 100
      t.datetime :retired_at
      t.string :retired_by, limit: 100
      t.datetime :supported_until
      t.datetime :revoked_at
      t.string :revoked_by, limit: 100
      t.string :revocation_severity, limit: 32
      t.string :revoked_reason, limit: 500
      t.timestamps
    end
    add_index :coworker_base_releases, :runtime_image_id, unique: true, name: "idx_cbr_image" unless index_exists?(:coworker_base_releases, :runtime_image_id, name: "idx_cbr_image")
    add_index :coworker_base_releases, :active_key, unique: true, name: "idx_cbr_active_key" unless index_exists?(:coworker_base_releases, :active_key, name: "idx_cbr_active_key")
    add_index :coworker_base_releases, %i[platform status], name: "idx_cbr_platform_status" unless index_exists?(:coworker_base_releases, %i[platform status], name: "idx_cbr_platform_status")
  end

  def down
    drop_table :coworker_base_releases, if_exists: true
  end
end
