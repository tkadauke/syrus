# The table predates the plugin, so its name predates the rule that a plugin's
# tables carry the plugin's prefix. "chat_" described where a walkthrough is
# attached rather than who owns it, which is exactly the confusion the prefix
# rule exists to prevent.
class RenameChatVideoWalkthroughsToVideoWalkthroughs < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:chat_video_walkthroughs)
    return if table_exists?(:video_walkthroughs)

    rename_table :chat_video_walkthroughs, :video_walkthroughs
  end

  def down
    return unless table_exists?(:video_walkthroughs)
    return if table_exists?(:chat_video_walkthroughs)

    rename_table :video_walkthroughs, :chat_video_walkthroughs
  end
end
