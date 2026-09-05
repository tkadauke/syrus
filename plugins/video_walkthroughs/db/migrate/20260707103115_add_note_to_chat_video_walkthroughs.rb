class AddNoteToChatVideoWalkthroughs < ActiveRecord::Migration[8.1]
  # The user's message sent alongside the video. Persisted (not a transient
  # job kwarg) so a retried analysis re-injects the user's guidance instead
  # of silently dropping it — review finding on PR #1627.
  def up
    add_column :chat_video_walkthroughs, :note, :text unless column_exists?(:chat_video_walkthroughs, :note)
  end

  def down
    remove_column :chat_video_walkthroughs, :note if column_exists?(:chat_video_walkthroughs, :note)
  end
end
