class GeneralizeAgentQuestionsForWorkflowRuns < ActiveRecord::Migration[8.1]
  def up
    change_column_null :chat_agent_questions, :chat_session_id, true if column_exists?(:chat_agent_questions, :chat_session_id)
    add_reference :chat_agent_questions, :run, null: true, foreign_key: false unless column_exists?(:chat_agent_questions, :run_id)
    add_reference :chat_agent_questions, :answered_by, null: true, foreign_key: false unless column_exists?(:chat_agent_questions, :answered_by_id)
    add_column :chat_agent_questions, :answer_source, :string unless column_exists?(:chat_agent_questions, :answer_source)
    add_column :chat_agent_questions, :defaults, :json unless column_exists?(:chat_agent_questions, :defaults)
    add_column :chat_agent_questions, :times_out_at, :datetime unless column_exists?(:chat_agent_questions, :times_out_at)
    add_column :chat_agent_questions, :timed_out_at, :datetime unless column_exists?(:chat_agent_questions, :timed_out_at)
    add_column :chat_agent_questions, :withdrawn_at, :datetime unless column_exists?(:chat_agent_questions, :withdrawn_at)

    add_index :chat_agent_questions, [ :run_id, :answered_at, :expired_at ], name: "idx_agent_questions_run_active" unless index_exists?(:chat_agent_questions, [ :run_id, :answered_at, :expired_at ], name: "idx_agent_questions_run_active")
  end

  def down
    remove_index :chat_agent_questions, name: "idx_agent_questions_run_active" if index_exists?(:chat_agent_questions, name: "idx_agent_questions_run_active")
    %i[withdrawn_at timed_out_at times_out_at defaults answer_source answered_by_id run_id].each do |column|
      remove_column :chat_agent_questions, column if column_exists?(:chat_agent_questions, column)
    end
    change_column_null :chat_agent_questions, :chat_session_id, false if column_exists?(:chat_agent_questions, :chat_session_id)
  end
end
