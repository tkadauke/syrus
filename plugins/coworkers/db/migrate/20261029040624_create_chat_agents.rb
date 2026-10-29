class CreateChatAgents < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_agents, if_not_exists: true do |t|
      t.references :chat_session, null: false
      t.references :coworker, null: false
      t.references :added_by_user, null: false

      t.timestamps
    end
    add_index :chat_agents, [ :chat_session_id, :coworker_id ], unique: true unless index_exists?(:chat_agents, [ :chat_session_id, :coworker_id ], unique: true)
  end

  def down = drop_table(:chat_agents, if_exists: true)
end
