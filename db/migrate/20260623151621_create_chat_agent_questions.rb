class CreateChatAgentQuestions < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_agent_questions, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.text :question, null: false
      t.json :options
      t.text :answer
      t.datetime :asked_at, null: false
      t.datetime :answered_at
      t.datetime :expired_at

      t.timestamps
    end

    unless index_exists?(:chat_agent_questions, [ :chat_session_id, :answered_at, :expired_at ], name: "idx_chat_agent_questions_active")
      add_index :chat_agent_questions, [ :chat_session_id, :answered_at, :expired_at ], name: "idx_chat_agent_questions_active"
    end
  end

  def down
    drop_table :chat_agent_questions, if_exists: true
  end
end
