# The Telegram and Discord plugins now keep their bot token in an
# instance-owned connected account, so both depend on the Connected Accounts
# plugin (which in turn needs Credential Store). A plugin whose dependency is
# disabled is unhealthy and stops delivering, so instances that already run
# either platform get the two dependencies enabled here. Instances that run
# neither are left alone. Idempotent: records already enabled are untouched.
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
  end

  def down
    # Enabling a plugin is not reverted; the operator owns that choice.
  end
end
