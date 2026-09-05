class CreateBuildCacheRepositorySettings < ActiveRecord::Migration[8.1]
  def up
    create_table :build_cache_repository_settings, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true, index: { unique: true }
      t.boolean :basedirs_safe, null: false, default: false
      t.timestamps
    end
  end

  def down
    drop_table :build_cache_repository_settings, if_exists: true
  end
end
