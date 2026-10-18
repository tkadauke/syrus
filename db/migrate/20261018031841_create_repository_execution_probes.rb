class CreateRepositoryExecutionProbes < ActiveRecord::Migration[8.1]
  def change
    create_table :repository_execution_probes, if_not_exists: true do |t|
      t.references :repository, null: false
      t.references :requested_by, null: false
      t.string :status, null: false, default: "queued"
      t.string :revision
      t.json :result, null: false
      t.datetime :started_at
      t.datetime :completed_at
      t.boolean :warning_override, null: false, default: false

      t.timestamps
    end
  end
end
