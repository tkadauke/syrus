# The Telegram and Discord plugins now keep their bot token in an
# instance-owned connected account, so both depend on the Connected Accounts
# plugin (which in turn needs Credential Store). A plugin whose dependency is
# disabled is unhealthy and stops delivering, so instances that already run
# either platform get the two dependencies enabled here. Instances that run
# neither are left alone.
#
# Those plugins (and Telegram, which is now experimental because it rides on
# them) are experimental, and an experimental plugin is only active while beta
# mode is on. Beta mode is therefore switched on for the same instances;
# without it the platforms would silently stop delivering after the upgrade.
# Beta mode does not enable any plugin by itself.
#
# Idempotent: records already enabled and a beta mode already on are untouched.
class EnableConnectedAccountsForBotTokenPlugins < ActiveRecord::Migration[8.1]
  PLATFORM_PLUGINS = %w[telegram discord].freeze
  DEPENDENCIES = %w[credential_store connected_accounts].freeze

  def up
    return unless table_exists?(:plugin_records)
    return unless PluginRecord.where(name: PLATFORM_PLUGINS, enabled: true).exists?

    DEPENDENCIES.each do |name|
      record = PluginRecord.find_or_initialize_by(name: name)
      next if record.persisted? && record.enabled?

      record.enabled = true
      record.save!
    end
    enable_beta_mode
  end

  def down
    # Enabling a plugin or beta mode is not reverted; the operator owns that choice.
  end

  private

  def enable_beta_mode
    return unless table_exists?(:app_settings) && column_exists?(:app_settings, :beta_mode_enabled)

    execute("UPDATE app_settings SET beta_mode_enabled = #{quoted_true} WHERE beta_mode_enabled IS NULL OR beta_mode_enabled = #{quoted_false}")
  end
end
