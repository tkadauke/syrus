class CreateChatAgents < ActiveRecord::Migration[8.1]
  def up
    create_table :coworkers_chat_agents, if_not_exists: true do |t|
      t.references :chat_session, null: false
      t.references :coworker, null: false
      t.references :added_by_user, null: false

      t.timestamps
    end
    add_index :coworkers_chat_agents, [ :chat_session_id, :coworker_id ], unique: true, name: "idx_coworkers_chat_agents_unique_roster" unless index_exists?(:coworkers_chat_agents, [ :chat_session_id, :coworker_id ], unique: true)
  end

  def down = drop_table(:coworkers_chat_agents, if_exists: true)
end
