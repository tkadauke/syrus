class ChangeChatAgentQuestionsToBatchShape < ActiveRecord::Migration[8.1]
  # This table holds transient operational UI state (in-flight agent
  # questions), not long-lived audit history, so this is a clean column
  # swap rather than a backfilled rename: any unanswered questions asked
  # before this migration deploys are dropped, not migrated to the new
  # batch shape.
  def up
    add_column :chat_agent_questions, :questions, :json unless column_exists?(:chat_agent_questions, :questions)
    add_column :chat_agent_questions, :answers, :json unless column_exists?(:chat_agent_questions, :answers)
    remove_column :chat_agent_questions, :question if column_exists?(:chat_agent_questions, :question)
    remove_column :chat_agent_questions, :options if column_exists?(:chat_agent_questions, :options)
    remove_column :chat_agent_questions, :answer if column_exists?(:chat_agent_questions, :answer)
  end

  def down
    add_column :chat_agent_questions, :question, :text unless column_exists?(:chat_agent_questions, :question)
    add_column :chat_agent_questions, :options, :json unless column_exists?(:chat_agent_questions, :options)
    add_column :chat_agent_questions, :answer, :text unless column_exists?(:chat_agent_questions, :answer)
    remove_column :chat_agent_questions, :questions if column_exists?(:chat_agent_questions, :questions)
    remove_column :chat_agent_questions, :answers if column_exists?(:chat_agent_questions, :answers)
  end
end
