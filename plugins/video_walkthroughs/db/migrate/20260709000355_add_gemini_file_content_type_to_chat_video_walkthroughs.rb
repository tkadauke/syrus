class AddGeminiFileContentTypeToChatVideoWalkthroughs < ActiveRecord::Migration[8.1]
  # The MIME type of the bytes ACTUALLY uploaded to Gemini's Files API, captured
  # at upload time. The row's content_type can drift after upload (the analysis
  # job transcodes the stored blob to mp4 post-analysis), so the retained-file
  # "zoom in" path must reference the mime of what was uploaded — not the current
  # content_type — or the fileData.mimeType mismatches the uploaded bytes.
  def up
    unless column_exists?(:chat_video_walkthroughs, :gemini_file_content_type)
      add_column :chat_video_walkthroughs, :gemini_file_content_type, :string
    end
  end

  def down
    if column_exists?(:chat_video_walkthroughs, :gemini_file_content_type)
      remove_column :chat_video_walkthroughs, :gemini_file_content_type
    end
  end
end
