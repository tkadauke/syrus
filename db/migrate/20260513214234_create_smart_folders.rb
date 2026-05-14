class CreateSmartFolders < ActiveRecord::Migration[8.1]
  def change
    create_table :smart_folders do |t|
      t.string :name, null: false
      t.references :user, foreign_key: true
      t.string :kind, null: false
      t.json :filter, null: false, default: {}
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :smart_folders, :kind
    add_index :smart_folders, [ :user_id, :position ]
    add_index :smart_folders, [ :user_id, :name ], unique: true
  end
end
