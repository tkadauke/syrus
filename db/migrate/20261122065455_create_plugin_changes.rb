class CreatePluginChanges < ActiveRecord::Migration[8.1]
  def up
    create_table :plugin_changes, if_not_exists: true do |t|
      t.string :plugin_name, null: false
      t.string :action, null: false
      t.references :plugin_release, null: true, foreign_key: false
      t.json :capability_manifest
      t.string :status, null: false
      t.references :staged_by, null: false, foreign_key: false
      t.references :confirmed_by, null: true, foreign_key: false
      t.datetime :confirmed_at

      t.timestamps
    end
    add_index :plugin_changes, %i[plugin_name status] unless index_exists?(:plugin_changes, %i[plugin_name status])
  end

  def down
    drop_table :plugin_changes, if_exists: true
  end
end
