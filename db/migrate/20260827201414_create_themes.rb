class CreateThemes < ActiveRecord::Migration[8.1]
  def change
    create_table :themes, if_not_exists: true do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.boolean :built_in, null: false, default: false
      t.references :owner_user, null: true
      t.json :tokens
      t.text :prompt

      t.timestamps
    end

    add_index :themes, :slug, unique: true unless index_exists?(:themes, :slug, unique: true)
  end
end
