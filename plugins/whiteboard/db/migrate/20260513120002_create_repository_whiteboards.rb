class CreateRepositoryWhiteboards < ActiveRecord::Migration[8.1]
  def change
    create_table :repository_whiteboards do |t|
      t.references :repository, null: false, foreign_key: true, index: { unique: true }
      t.json :scene_json, null: false
      t.integer :version, null: false, default: 0

      t.timestamps
    end
  end
end
