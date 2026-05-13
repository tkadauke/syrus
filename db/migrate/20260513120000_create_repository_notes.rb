class CreateRepositoryNotes < ActiveRecord::Migration[8.1]
  def change
    create_table :repository_notes do |t|
      t.references :repository, null: false, foreign_key: true
      t.text :body, null: false
      t.string :author, null: false
      t.datetime :removed_at
      t.datetime :created_at, null: false
    end

    add_index :repository_notes, [ :repository_id, :removed_at, :created_at ]
  end
end
