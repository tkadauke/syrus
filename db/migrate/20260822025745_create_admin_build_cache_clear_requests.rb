class CreateAdminBuildCacheClearRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :admin_build_cache_clear_requests, if_not_exists: true do |t|
      t.references :user, null: false, foreign_key: true
      t.string :scope, null: false
      t.integer :older_than_days
      t.text :reason, null: false
      t.string :state, null: false, default: "pending"
      t.json :result
      t.datetime :confirmed_at
      t.datetime :cancelled_at

      t.timestamps
    end

    add_index :admin_build_cache_clear_requests, :state unless index_exists?(:admin_build_cache_clear_requests, :state)
  end
end
