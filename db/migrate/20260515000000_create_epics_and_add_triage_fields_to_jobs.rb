class CreateEpicsAndAddTriageFieldsToJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :epics do |t|
      t.references :user, null: false, foreign_key: true
      t.references :repository, null: false, foreign_key: true
      t.string :title, null: false
      t.text :description
      t.string :state, null: false, default: "backlog"

      t.timestamps
    end

    add_reference :jobs, :epic, foreign_key: true, index: false
    add_column :jobs, :validity, :string, null: false, default: "valid"
    add_column :jobs, :invalidation_reason, :text
    add_column :jobs, :invalidation_evidence, :json, null: false, default: []
    add_column :jobs, :triaging_reason, :string, null: false, default: "classifier_pending"

    change_column_default :jobs, :state, from: "open", to: "triaging"
    add_index :jobs, :validity
    add_index :jobs, :triaging_reason
  end
end
