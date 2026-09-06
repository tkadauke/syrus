class CreatePluginRecords < ActiveRecord::Migration[8.1]
  def up
    create_table :plugin_records, if_not_exists: true do |t|
      t.string  :name,    null: false
      t.boolean :enabled, null: false, default: true
      t.json    :config
      t.timestamps
    end

    add_index :plugin_records, :name, unique: true unless index_exists?(:plugin_records, :name)

    execute "UPDATE plugin_records SET config = '{}' WHERE config IS NULL"
    change_column_null :plugin_records, :config, false
  end

  def down
    drop_table :plugin_records, if_exists: true
  end
end
