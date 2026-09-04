class DropOrphanedChatWhiteboardsTable < ActiveRecord::Migration[8.1]
  # `chat_whiteboards` was created by a superseded iteration of the chat
  # whiteboard (the surviving table is `whiteboards`, now
  # `whiteboard_tools_boards`) and was never dropped. Nothing has ever read it:
  # no model maps to it and no code names it outside its own migration.
  def up
    drop_table :chat_whiteboards, if_exists: true
  end

  def down
    create_table :chat_whiteboards, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true, index: { unique: true }
      t.json :scene_json, null: false
      t.integer :version, null: false, default: 0
      t.datetime :last_edited_at

      t.timestamps
    end
  end
end
