class CreateWhiteboards < ActiveRecord::Migration[8.1]
  def change
    create_table :whiteboards do |t|
      t.references :chat_session, null: false, foreign_key: true, index: { unique: true }
      # MySQL 8 rejects defaults on JSON columns; the empty scene is
      # filled in by Whiteboard::Board#after_initialize instead.
      t.json :scene_json, null: false
      t.integer :version, null: false, default: 0
      t.datetime :last_edited_at

      t.timestamps
    end
  end
end
