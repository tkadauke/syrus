class RenameWhiteboardTablesToWhiteboardToolsPrefix < ActiveRecord::Migration[8.1]
  # Plugin-owned tables carry their plugin's prefix (see
  # bin/check-plugin-model-namespaces), so the models can move out of core.
  def up
    rename_table :whiteboards, :whiteboard_tools_boards if table_exists?(:whiteboards) && !table_exists?(:whiteboard_tools_boards)
    rename_table :whiteboard_snapshots, :whiteboard_tools_snapshots if table_exists?(:whiteboard_snapshots) && !table_exists?(:whiteboard_tools_snapshots)
  end

  def down
    rename_table :whiteboard_tools_boards, :whiteboards if table_exists?(:whiteboard_tools_boards) && !table_exists?(:whiteboards)
    rename_table :whiteboard_tools_snapshots, :whiteboard_snapshots if table_exists?(:whiteboard_tools_snapshots) && !table_exists?(:whiteboard_snapshots)
  end
end
