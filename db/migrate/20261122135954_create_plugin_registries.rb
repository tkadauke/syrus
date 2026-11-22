class CreatePluginRegistries < ActiveRecord::Migration[8.1]
  def up
    create_table :plugin_registries, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.boolean :enabled, null: false, default: true
      t.boolean :environment_managed, null: false, default: false
      t.datetime :removed_at
      t.references :created_by, null: true, foreign_key: false

      t.timestamps
    end
    add_column :plugin_registries, :environment_managed, :boolean, null: false, default: false unless column_exists?(:plugin_registries, :environment_managed)
    add_column :plugin_registries, :removed_at, :datetime unless column_exists?(:plugin_registries, :removed_at)
    add_index :plugin_registries, :name, unique: true unless index_exists?(:plugin_registries, :name, unique: true)
    add_index :plugin_registries, :url, unique: true unless index_exists?(:plugin_registries, :url, unique: true)
  end

  def down = drop_table(:plugin_registries, if_exists: true)
end
