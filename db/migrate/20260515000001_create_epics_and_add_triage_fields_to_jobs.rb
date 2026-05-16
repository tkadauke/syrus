class CreateEpicsAndAddTriageFieldsToJobs < ActiveRecord::Migration[8.1]
  def up
    unless table_exists?(:epics)
      create_table :epics do |t|
        t.references :user, null: false, foreign_key: true
        t.references :repository, null: false, foreign_key: true
        t.string :title, null: false
        t.text :description
        t.string :state, null: false, default: "backlog"

        t.timestamps
      end
    end

    add_reference :epics, :repository, null: false, foreign_key: true unless column_exists?(:epics, :repository_id)
    add_reference :jobs, :epic, foreign_key: true, index: false unless column_exists?(:jobs, :epic_id)
    add_column :jobs, :validity, :string, null: false, default: "valid" unless column_exists?(:jobs, :validity)
    add_column :jobs, :invalidation_reason, :text unless column_exists?(:jobs, :invalidation_reason)
    add_invalidation_evidence_column
    add_column :jobs, :triaging_reason, :string, null: false, default: "classifier_pending" unless column_exists?(:jobs, :triaging_reason)

    change_state_default_to_triaging
    add_index :jobs, :validity unless index_exists?(:jobs, :validity, name: "index_jobs_on_validity")
    add_index :jobs, :triaging_reason unless index_exists?(:jobs, :triaging_reason, name: "index_jobs_on_triaging_reason")
  end

  def down
    remove_index :jobs, name: "index_jobs_on_triaging_reason" if index_exists?(:jobs, :triaging_reason, name: "index_jobs_on_triaging_reason")
    remove_index :jobs, name: "index_jobs_on_validity" if index_exists?(:jobs, :validity, name: "index_jobs_on_validity")
    change_column_default :jobs, :state, from: "triaging", to: "open" if jobs_state_default == "triaging"

    remove_column :jobs, :triaging_reason if column_exists?(:jobs, :triaging_reason)
    remove_column :jobs, :invalidation_evidence if column_exists?(:jobs, :invalidation_evidence)
    remove_column :jobs, :invalidation_reason if column_exists?(:jobs, :invalidation_reason)
    remove_column :jobs, :validity if column_exists?(:jobs, :validity)
    remove_reference :jobs, :epic, foreign_key: true if column_exists?(:jobs, :epic_id)
  end

  private

  def add_invalidation_evidence_column
    return if column_exists?(:jobs, :invalidation_evidence)

    # MySQL rejects defaults on JSON columns. The model supplies the
    # create-time default, and this migration backfills existing rows
    # before enforcing NOT NULL.
    add_column :jobs, :invalidation_evidence, :json
    if mysql?
      execute "UPDATE jobs SET invalidation_evidence = JSON_ARRAY() WHERE invalidation_evidence IS NULL"
    else
      execute "UPDATE jobs SET invalidation_evidence = '[]' WHERE invalidation_evidence IS NULL"
    end
    change_column_null :jobs, :invalidation_evidence, false
  end

  def change_state_default_to_triaging
    return if jobs_state_default == "triaging"

    change_column_default :jobs, :state, from: jobs_state_default, to: "triaging"
  end

  def jobs_state_default
    column = columns(:jobs).find { |candidate| candidate.name == "state" }
    column&.default
  end

  def mysql?
    connection.adapter_name.downcase.include?("mysql")
  end
end
