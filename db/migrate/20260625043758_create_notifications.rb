class CreateNotifications < ActiveRecord::Migration[8.1]
  def up
    create_table :notifications, if_not_exists: true do |t|
      t.references :user, null: false, index: true, foreign_key: true
      t.string :kind, null: false
      t.datetime :read_at
      t.references :job, null: true, foreign_key: true
      t.string :pr_url
      t.string :body, null: false
      t.datetime :created_at, null: false
    end
  end

  def down
    drop_table :notifications, if_exists: true
  end
end
