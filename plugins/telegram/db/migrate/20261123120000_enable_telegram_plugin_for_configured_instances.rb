class EnableTelegramPluginForConfiguredInstances < ActiveRecord::Migration[8.1]
  # Telegram moved from core into the bundled `telegram` plugin, which is
  # disabled by default. Instances that already had a Telegram bot token must
  # keep working after upgrade, so enable the plugin for them. Instances
  # without a token are left alone (the plugin registers itself disabled at
  # boot). Idempotent: re-running leaves an already-enabled record enabled.
  def up
    return unless table_exists?(:plugin_records) && table_exists?(:app_settings)
    return unless column_exists?(:app_settings, :telegram_bot_token)
    return unless telegram_token_configured?

    PluginRecord.reset_column_information
    record = PluginRecord.find_or_initialize_by(name: "telegram")
    if record.new_record?
      record.default_enabled = false
      record.disableable = true
    end
    record.enabled = true
    record.save!
  end

  def down
    # Enablement is operator state; leaving the plugin enabled is harmless.
  end

  private

  def telegram_token_configured?
    select_values("SELECT telegram_bot_token FROM app_settings").any?(&:present?)
  end
end
