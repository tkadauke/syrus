class CreateWhiteboardSnapshots < ActiveRecord::Migration[8.1]
  def up
    create_table :whiteboard_snapshots, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true, index: true
      t.string :name
      t.json :scene_json, null: false
      t.string :snapshot_kind, null: false
      t.integer :element_count, null: false
      t.datetime :created_at, null: false
    end
  end

  def down
    drop_table :whiteboard_snapshots, if_exists: true
  end
end
