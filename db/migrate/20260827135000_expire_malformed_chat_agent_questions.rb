class ExpireMalformedChatAgentQuestions < ActiveRecord::Migration[8.1]
  class MigrationChatAgentQuestion < ActiveRecord::Base
    self.table_name = "chat_agent_questions"
  end

  def up
    return unless table_exists?(:chat_agent_questions)
    return unless column_exists?(:chat_agent_questions, :questions)

    MigrationChatAgentQuestion.reset_column_information
    now = Time.current

    MigrationChatAgentQuestion
      .where(answered_at: nil, expired_at: nil, questions: nil)
      .update_all(expired_at: now, updated_at: now)
  end

  def down
    # Data-only cleanup. Do not resurrect expired operator prompts.
  end
end
