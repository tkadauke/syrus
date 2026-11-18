class AddMentionOwnerDestinationsAndAfterReply < ActiveRecord::Migration[8.1]
  def up
    add_column :coworkers_chat_agents, :after_reply, :string, default: "wake", null: false unless column_exists?(:coworkers_chat_agents, :after_reply)
  end

  def down
    remove_column :coworkers_chat_agents, :after_reply if column_exists?(:coworkers_chat_agents, :after_reply)
  end
end
