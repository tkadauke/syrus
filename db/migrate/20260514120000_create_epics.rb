class CreateEpics < ActiveRecord::Migration[8.1]
  def change
    create_table :epics do |t|
      t.integer :number, null: false
      t.string :title, null: false
      t.text :description
      t.string :state, default: "backlog", null: false
      t.datetime :done_at
      t.string :github_issue_url
      t.references :user, null: false, foreign_key: true

      t.timestamps
    end

    add_index :epics, :number, unique: true
    add_index :epics, [ :user_id, :state ]
  end
end
