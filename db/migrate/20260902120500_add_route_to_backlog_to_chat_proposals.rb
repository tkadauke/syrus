class AddRouteToBacklogToChatProposals < ActiveRecord::Migration[8.1]
  def up
    add_column :chat_proposals, :route_to_backlog, :boolean, null: false, default: false unless column_exists?(:chat_proposals, :route_to_backlog)
  end

  def down
    remove_column :chat_proposals, :route_to_backlog if column_exists?(:chat_proposals, :route_to_backlog)
  end
end
