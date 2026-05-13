class AddOperatorChatDisabledToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :operator_chat_disabled, :boolean, null: false, default: false
  end
end
