class AddExternalPrBotRecoveryToJobs < ActiveRecord::Migration[8.1]
  # Records what Syrus did on its own about a bot-authored external PR's
  # requested changes (which reviews a repair addressed, when it asked the bot
  # to recreate the PR) so the poller acts once per situation instead of on
  # every poll. No database default: JSON column defaults are not portable to
  # MySQL.
  def up
    add_column :jobs, :external_pr_bot_recovery, :json unless column_exists?(:jobs, :external_pr_bot_recovery)
  end

  def down
    remove_column :jobs, :external_pr_bot_recovery if column_exists?(:jobs, :external_pr_bot_recovery)
  end
end
