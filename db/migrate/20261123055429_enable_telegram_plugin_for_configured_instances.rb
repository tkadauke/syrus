# Telegram moved from core into the bundled `telegram` plugin, which is
# disabled by default. Instances that already had a bot token configured must
# keep polling after the upgrade, so enable the plugin for them. Idempotent:
# a second run finds the record already enabled, and instances without a
# token are left alone (the plugin stays disabled there).
class EnableTelegramPluginForConfiguredInstances < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:plugin_records) && table_exists?(:app_settings)
    return unless column_exists?(:app_settings, :telegram_bot_token)
    return unless token_configured?

    record = PluginRecord.find_or_initialize_by(name: "telegram")
    return if record.persisted? && record.enabled?

    record.enabled = true
    record.save!
  end

  def down
    # Enabling a plugin is not reverted; the operator owns that choice.
  end

  private

  def token_configured?
    value = select_value("SELECT telegram_bot_token FROM app_settings WHERE telegram_bot_token IS NOT NULL AND telegram_bot_token <> '' LIMIT 1")
    value.present?
  end
end
