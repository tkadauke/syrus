class CreateFeatures < ActiveRecord::Migration[8.1]
  def up
    create_table :features, if_not_exists: true do |t|
      t.string :slug, null: false
      t.string :category, null: false
      t.string :name, null: false
      t.text :description
      t.boolean :default_enabled, null: false, default: false
      t.boolean :enabled, null: false, default: false

      t.timestamps
    end

    add_index :features, :slug, unique: true unless index_exists?(:features, :slug)
  end

  def down
    drop_table :features, if_exists: true
  end
end
