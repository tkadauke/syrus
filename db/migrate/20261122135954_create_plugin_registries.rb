class CreatePluginRegistries < ActiveRecord::Migration[8.1]
  def up
    create_table :plugin_registries, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.boolean :enabled, null: false, default: true
      t.references :created_by, null: true, foreign_key: false

      t.timestamps
    end
    add_index :plugin_registries, :name, unique: true unless index_exists?(:plugin_registries, :name, unique: true)
    add_index :plugin_registries, :url, unique: true unless index_exists?(:plugin_registries, :url, unique: true)
  end

  def down = drop_table(:plugin_registries, if_exists: true)
end
