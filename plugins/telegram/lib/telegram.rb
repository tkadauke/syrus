module SyrusTelegram
  extend Syrus::PluginApi

  syrus_plugin "telegram" do
    requires_syrus nil
    experimental false
    display_name "Telegram"
    description "Links Telegram accounts and delivers/receives chat messages over bot long-polling."
    long_description "Telegram adds a platform-delivery channel for Syrus chat. It links Telegram users to Syrus accounts, long-polls the Telegram Bot API for direct messages, and delivers chat replies back to Telegram so operators can interact with Syrus away from the web UI.\n\nThe plugin is disabled by default on new instances because it requires a Telegram bot token. Instances that already had a Telegram bot token configured when this plugin was extracted from core have it enabled automatically on upgrade."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "platform_delivery"
    default_enabled false
    disableable true
    provides platform_delivery: "Telegram::PlatformAdapter"
  end
end
