class CreateSyrusDevPermissionFactoryResets < ActiveRecord::Migration[8.1]
  def change
    create_table :syrus_dev_permission_factory_resets do |t|
      t.references :initiated_by_user, null: false
      t.string :scope_type, null: false
      t.string :scope_id
      t.string :default_version, null: false
      t.string :outcome, null: false
      t.json :counts, null: false
      t.text :error_message
      t.datetime :completed_at
      t.timestamps
    end

    unless index_exists?(:syrus_dev_permission_factory_resets, [ :scope_type, :scope_id, :created_at ],
      name: "idx_syrus_dev_permission_resets_scope")
      add_index :syrus_dev_permission_factory_resets, [ :scope_type, :scope_id, :created_at ],
        name: "idx_syrus_dev_permission_resets_scope"
    end
  end
end
