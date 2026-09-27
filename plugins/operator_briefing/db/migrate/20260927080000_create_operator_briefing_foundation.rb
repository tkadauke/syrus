class CreateOperatorBriefingFoundation < ActiveRecord::Migration[8.1]
  def change
    create_table :operator_briefing_review_findings, if_not_exists: true do |t|
      t.references :workflow, null: false, foreign_key: false
      t.references :step, foreign_key: false
      t.references :run, foreign_key: false
      t.string :review_kind, null: false
      t.integer :iteration, null: false
      t.string :verdict, null: false
      t.text :critique, null: false
      t.json :artifacts
      t.boolean :overridden, null: false, default: false
      t.datetime :overridden_at

      t.timestamps
    end

    unless index_exists?(:operator_briefing_review_findings, [ :workflow_id, :review_kind, :iteration, :run_id ], name: "idx_operator_briefing_review_findings_identity")
      add_index :operator_briefing_review_findings,
                [ :workflow_id, :review_kind, :iteration, :run_id ],
                unique: true,
                name: "idx_operator_briefing_review_findings_identity"
    end
    unless index_exists?(:operator_briefing_review_findings, [ :workflow_id, :review_kind, :verdict, :overridden ], name: "idx_operator_briefing_review_findings_lookup")
      add_index :operator_briefing_review_findings,
                [ :workflow_id, :review_kind, :verdict, :overridden ],
                name: "idx_operator_briefing_review_findings_lookup"
    end

    create_table :operator_briefing_workflow_notable_changes, if_not_exists: true do |t|
      t.references :workflow, null: false, foreign_key: false
      t.references :job, null: false, foreign_key: false
      t.references :repository, null: false, foreign_key: false
      t.string :detector_key, null: false
      t.string :fact_key, null: false
      t.string :severity, null: false
      t.text :summary, null: false
      t.json :evidence

      t.timestamps
    end

    unless index_exists?(:operator_briefing_workflow_notable_changes, [ :workflow_id, :fact_key ], name: "idx_operator_briefing_notable_changes_identity")
      add_index :operator_briefing_workflow_notable_changes,
                [ :workflow_id, :fact_key ],
                unique: true,
                name: "idx_operator_briefing_notable_changes_identity"
    end
    unless index_exists?(:operator_briefing_workflow_notable_changes, [ :repository_id, :severity, :created_at ], name: "idx_operator_briefing_notable_changes_repo_severity")
      add_index :operator_briefing_workflow_notable_changes,
                [ :repository_id, :severity, :created_at ],
                name: "idx_operator_briefing_notable_changes_repo_severity"
    end

    create_table :operator_briefing_items, if_not_exists: true do |t|
      t.bigint :briefing_id
      t.string :severity, null: false
      t.string :source_type
      t.bigint :source_id
      t.text :narrative, null: false
      t.json :evidence

      t.timestamps
    end

    add_index :operator_briefing_items, :briefing_id unless index_exists?(:operator_briefing_items, :briefing_id)
    unless index_exists?(:operator_briefing_items, [ :source_type, :source_id ], name: "idx_operator_briefing_items_source")
      add_index :operator_briefing_items,
                [ :source_type, :source_id ],
                name: "idx_operator_briefing_items_source"
    end
    unless index_exists?(:operator_briefing_items, [ :severity, :created_at ], name: "idx_operator_briefing_items_severity")
      add_index :operator_briefing_items,
                [ :severity, :created_at ],
                name: "idx_operator_briefing_items_severity"
    end
  end
end
