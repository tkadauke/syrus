class DropRepositoryWhiteboards < ActiveRecord::Migration[8.1]
  def up
    drop_table :repository_whiteboards, if_exists: true
  end

  def down
    create_table :repository_whiteboards, if_not_exists: true do |t|
      t.references :repository, null: false, foreign_key: true, index: { unique: true }
      t.json :scene_json, null: false
      t.integer :version, null: false, default: 0

      t.timestamps
    end
  end
end
