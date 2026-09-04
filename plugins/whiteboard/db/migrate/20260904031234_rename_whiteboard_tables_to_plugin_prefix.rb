class RenameWhiteboardTablesToPluginPrefix < ActiveRecord::Migration[8.1]
  # Plugin-owned tables carry their plugin's prefix (see
  # bin/check-plugin-model-namespaces), so the models can move out of core.
  # `whiteboard_snapshots` already satisfied that; only the board table moves.
  def up
    rename_table :whiteboards, :whiteboard_boards if table_exists?(:whiteboards) && !table_exists?(:whiteboard_boards)
  end

  def down
    rename_table :whiteboard_boards, :whiteboards if table_exists?(:whiteboard_boards) && !table_exists?(:whiteboards)
  end
end
