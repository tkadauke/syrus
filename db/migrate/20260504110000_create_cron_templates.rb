class CreateCronTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :cron_templates do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.text :description
      t.text :prompt, null: false
      t.string :cron_expression, null: false
      t.string :pr_pileup_policy, null: false, default: "skip"
      t.boolean :enabled, null: false, default: true
      t.timestamps
    end

    add_reference :scheduled_tasks, :cron_template, null: true, foreign_key: true
  end
end
