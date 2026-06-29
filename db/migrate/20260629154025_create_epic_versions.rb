class CreateEpicVersions < ActiveRecord::Migration[8.1]
  def up
    create_table :epic_versions, if_not_exists: true do |t|
      t.references :epic, null: false, foreign_key: true
      t.references :user, null: true, foreign_key: true
      t.text :title_before
      t.text :title_after
      t.text :description_before
      t.text :description_after
      t.datetime :created_at, null: false
    end

    add_index :epic_versions, :epic_id unless index_exists?(:epic_versions, :epic_id)
  end

  def down
    drop_table :epic_versions, if_exists: true
  end
end
