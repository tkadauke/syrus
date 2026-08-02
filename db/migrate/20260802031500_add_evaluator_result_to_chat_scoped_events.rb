class AddEvaluatorResultToChatScopedEvents < ActiveRecord::Migration[8.1]
  def change
    unless column_exists?(:chat_scoped_events, :evaluator_state)
      add_column :chat_scoped_events, :evaluator_state, :string, null: false, default: "pending"
    end
    add_column :chat_scoped_events, :evaluator_result, :json unless column_exists?(:chat_scoped_events, :evaluator_result)
    add_column :chat_scoped_events, :evaluator_session_id, :string unless column_exists?(:chat_scoped_events, :evaluator_session_id)
    add_column :chat_scoped_events, :evaluator_error, :text unless column_exists?(:chat_scoped_events, :evaluator_error)
    add_column :chat_scoped_events, :evaluated_at, :datetime unless column_exists?(:chat_scoped_events, :evaluated_at)

    unless index_exists?(:chat_scoped_events, [ :evaluator_state, :created_at ], name: "idx_chat_scoped_events_evaluator")
      add_index :chat_scoped_events, [ :evaluator_state, :created_at ], name: "idx_chat_scoped_events_evaluator"
    end
  end
end
