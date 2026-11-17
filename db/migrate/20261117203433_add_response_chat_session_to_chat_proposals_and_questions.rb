class AddResponseChatSessionToChatProposalsAndQuestions < ActiveRecord::Migration[8.1]
  def up
    add_reference :chat_proposals, :response_chat_session, null: true, index: true, foreign_key: false unless column_exists?(:chat_proposals, :response_chat_session_id)
    add_reference :chat_agent_questions, :response_chat_session, null: true, index: true, foreign_key: false unless column_exists?(:chat_agent_questions, :response_chat_session_id)
  end

  def down
    remove_reference :chat_agent_questions, :response_chat_session, index: true, foreign_key: false if column_exists?(:chat_agent_questions, :response_chat_session_id)
    remove_reference :chat_proposals, :response_chat_session, index: true, foreign_key: false if column_exists?(:chat_proposals, :response_chat_session_id)
  end
end
