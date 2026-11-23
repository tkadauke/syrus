module SyrusTelegram
  extend Syrus::PluginApi

  syrus_plugin "telegram" do
    requires_syrus nil
    experimental true
    display_name "Telegram"
    description "Links Telegram accounts and delivers/receives chat messages over bot long-polling."
    long_description "Telegram adds a platform-delivery channel for Syrus chat. It links Telegram users to Syrus accounts, long-polls the Telegram Bot API for direct messages, and delivers chat replies back to Telegram so operators can interact with Syrus away from the web UI.\n\nThe plugin is disabled by default on new instances because it requires a Telegram bot token. Instances that already had a Telegram bot token configured when this plugin was extracted from core have it enabled automatically on upgrade, along with the Connected Accounts plugin that now holds the token and beta mode, which experimental plugins need in order to stay active."
    homepage "https://github.com/tkadauke/syrus"
    author "Thomas Kadauke"
    category "platform_delivery"
    default_enabled false
    disableable true
    depends_on [ "connected_accounts" ]
    provides "connected_accounts:provider" => [ {
      provider: "Telegram::Provider",
      key: "telegram_bot",
      display_name: "Telegram bot",
      authorization_kind: "token",
      system_service_identities: [ "telegram.platform" ],
      capabilities: %w[authorization exchange_code refresh revoke identity validate],
      callback_route: "/api/v1/app/connected_accounts/callback/telegram_bot",
      supports_read_only: false,
      configuration: { api_origins: [ "https://api.telegram.org/" ] },
      scopes: [
        {
          key: "telegram.bot",
          label: "Operate the Telegram bot",
          risk: "high",
          read_only: false,
          syrus_capabilities: [ "platform.deliver@v1" ]
        }
      ]
    } ]
    provides platform_delivery: "Telegram::PlatformAdapter"
  end
end
