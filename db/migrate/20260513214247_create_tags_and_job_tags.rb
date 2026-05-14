class CreateTagsAndJobTags < ActiveRecord::Migration[8.1]
  def change
    create_table :tags do |t|
      t.references :user, null: false, index: true
      t.integer :team_id
      t.string :name, null: false
      t.string :color, null: false, default: "gray"

      t.timestamps
    end

    add_index :tags, [ :user_id, :name ], unique: true
    add_index :tags, :team_id

    create_table :job_tags do |t|
      t.references :job, null: false, index: true
      t.references :tag, null: false, index: true

      t.timestamps
    end

    add_index :job_tags, [ :job_id, :tag_id ], unique: true
  end
end
