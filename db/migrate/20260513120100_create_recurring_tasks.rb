class CreateRecurringTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :recurring_tasks do |t|
      t.references :repository, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :cron_expression, null: false
      t.string :label, null: false
      t.text :prompt, null: false
      t.datetime :next_fire_at, null: false
      t.boolean :enabled, null: false, default: true

      t.timestamps
    end

    add_index :recurring_tasks, [ :enabled, :next_fire_at ]
  end
end
