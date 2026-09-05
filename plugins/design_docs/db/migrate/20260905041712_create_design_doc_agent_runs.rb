class CreateDesignDocAgentRuns < ActiveRecord::Migration[8.1]
  def up
    create_table :design_doc_agent_runs, if_not_exists: true do |t|
      t.references :design_doc, null: false, foreign_key: false
      t.references :design_doc_thread, null: false, foreign_key: false
      t.bigint :triggering_comment_id, null: false
      t.bigint :requested_by_user_id, null: false
      t.bigint :base_version_id
      t.string :agent_provider, null: false
      t.string :status, null: false, default: "queued"
      t.datetime :started_at
      t.datetime :finished_at
      t.text :result_summary
      t.text :error_message
      t.json :context_snapshot
      t.json :output_payload

      t.timestamps
    end

    add_index :design_doc_agent_runs, :requested_by_user_id unless index_exists?(:design_doc_agent_runs, :requested_by_user_id)
    add_index :design_doc_agent_runs, :base_version_id unless index_exists?(:design_doc_agent_runs, :base_version_id)
    unless index_exists?(:design_doc_agent_runs, [ :design_doc_thread_id, :status ], name: "index_design_doc_agent_runs_on_thread_and_status")
      add_index :design_doc_agent_runs, [ :design_doc_thread_id, :status ], name: "index_design_doc_agent_runs_on_thread_and_status"
    end
    unless index_exists?(:design_doc_agent_runs, :triggering_comment_id, name: "index_design_doc_agent_runs_on_triggering_comment")
      add_index :design_doc_agent_runs, :triggering_comment_id, unique: true, name: "index_design_doc_agent_runs_on_triggering_comment"
    end

    add_column :design_doc_comments, :design_doc_agent_run_id, :bigint unless column_exists?(:design_doc_comments, :design_doc_agent_run_id)
    add_index :design_doc_comments, :design_doc_agent_run_id unless index_exists?(:design_doc_comments, :design_doc_agent_run_id)

    add_column :design_doc_suggestions, :design_doc_agent_run_id, :bigint unless column_exists?(:design_doc_suggestions, :design_doc_agent_run_id)
    add_index :design_doc_suggestions, :design_doc_agent_run_id unless index_exists?(:design_doc_suggestions, :design_doc_agent_run_id)
  end

  def down
    remove_index :design_doc_suggestions, :design_doc_agent_run_id if index_exists?(:design_doc_suggestions, :design_doc_agent_run_id)
    remove_column :design_doc_suggestions, :design_doc_agent_run_id if column_exists?(:design_doc_suggestions, :design_doc_agent_run_id)

    remove_index :design_doc_comments, :design_doc_agent_run_id if index_exists?(:design_doc_comments, :design_doc_agent_run_id)
    remove_column :design_doc_comments, :design_doc_agent_run_id if column_exists?(:design_doc_comments, :design_doc_agent_run_id)

    drop_table :design_doc_agent_runs, if_exists: true
  end
end
