class CreateChatVideoWalkthroughs < ActiveRecord::Migration[8.1]
  def up
    create_table :chat_video_walkthroughs, if_not_exists: true do |t|
      t.references :chat_session, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      # uploaded → analyzing → analyzed | failed (model-level state machine)
      t.string :state, null: false, default: "uploaded"
      t.string :title
      # Client-measured (HTMLVideoElement.duration / the recorder clock) —
      # there is no ffmpeg in the image; Gemini decodes the video itself.
      t.integer :duration_seconds
      t.bigint :byte_size
      t.string :content_type
      # The Gemini Files API handle (48h retention upstream) + when we saw it
      # become ACTIVE, so re-analysis knows whether a re-upload is needed.
      t.string :gemini_file_uri
      t.datetime :gemini_file_active_at
      # JSON columns must not have DB defaults on MySQL 8 (see CLAUDE.md);
      # nullable + model-side seeding instead.
      t.json :analysis
      t.text :error_message
      t.datetime :analyzed_at
      t.timestamps
    end

    add_index :chat_video_walkthroughs, :state unless index_exists?(:chat_video_walkthroughs, :state)
  end

  def down
    drop_table :chat_video_walkthroughs, if_exists: true
  end
end
