class CreatePlannedExecutionOverrides < ActiveRecord::Migration[8.1]
  def change
    return if table_exists?(:planned_execution_overrides)

    create_table :planned_execution_overrides do |t|
      t.references :job, null: false, foreign_key: true
      t.references :workflow, null: true, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :profile, null: false
      t.text :reason, null: false
      t.json :previous_placement, null: false
      t.json :replacement_placement, null: false
      t.string :provenance, null: false

      t.timestamps
    end
  end
end
