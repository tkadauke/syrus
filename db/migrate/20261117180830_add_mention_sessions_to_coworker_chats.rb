class AddMentionSessionsToCoworkerChats < ActiveRecord::Migration[8.1]
  def up
    add_column :coworker_chats, :source_chat_session_id, :integer unless column_exists?(:coworker_chats, :source_chat_session_id)
    add_column :coworker_chats, :last_delivered_message_id, :integer unless column_exists?(:coworker_chats, :last_delivered_message_id)
    add_index :coworker_chats, [ :coworker_id, :source_chat_session_id ], unique: true,
      name: "idx_coworker_chats_mention_source" unless index_exists?(:coworker_chats, [ :coworker_id, :source_chat_session_id ], name: "idx_coworker_chats_mention_source")

    execute <<~SQL.squish
      INSERT INTO chat_shares (chat_session_id, target_type, target_id, shared_by_user_id, created_at)
      SELECT agents.chat_session_id, 'Coworkers::Coworker', agents.coworker_id, agents.added_by_user_id, CURRENT_TIMESTAMP
      FROM coworkers_chat_agents agents
      WHERE NOT EXISTS (
        SELECT 1 FROM chat_shares shares
        WHERE shares.chat_session_id = agents.chat_session_id
          AND shares.target_type = 'Coworkers::Coworker'
          AND shares.target_id = agents.coworker_id
      )
    SQL
  end

  def down
    remove_index :coworker_chats, name: "idx_coworker_chats_mention_source" if index_exists?(:coworker_chats, name: "idx_coworker_chats_mention_source")
    remove_column :coworker_chats, :last_delivered_message_id if column_exists?(:coworker_chats, :last_delivered_message_id)
    remove_column :coworker_chats, :source_chat_session_id if column_exists?(:coworker_chats, :source_chat_session_id)
  end
end
