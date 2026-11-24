module SyrusDiscord
  extend Syrus::PluginApi

  syrus_plugin "discord" do
    requires_syrus nil
    experimental true
    display_name "Discord"
    description "Links Discord accounts and delivers/receives chat messages over a Gateway DM listener."
    long_description "Discord adds a platform-delivery channel for Syrus chat. It links Discord users to Syrus accounts, listens for direct messages through the Gateway, and delivers chat replies back to Discord so operators can interact with Syrus away from the web UI.\n\nThe plugin is disabled by default because it requires Discord credentials and a running Gateway connection. Once configured, it behaves as another chat surface rather than a separate automation engine."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/discord.svg"
    author "Thomas Kadauke"
    category "platform_delivery"
    default_enabled false
    disableable true
    depends_on [ "connected_accounts" ]
    provides "connected_accounts:provider" => [ {
      provider: "Discord::Provider",
      key: "discord_bot",
      display_name: "Discord bot",
      authorization_kind: "token",
      system_service_identities: [ "discord.platform" ],
      capabilities: %w[authorization exchange_code refresh revoke identity validate],
      callback_route: "/api/v1/app/connected_accounts/callback/discord_bot",
      supports_read_only: false,
      configuration: { api_origins: [ "https://discord.com/api/v10/" ] },
      scopes: [
        {
          key: "discord.bot",
          label: "Operate the Discord bot",
          risk: "high",
          read_only: false,
          syrus_capabilities: [ "platform.deliver@v1" ]
        }
      ]
    } ]
    provides platform_delivery: "Discord::PlatformAdapter"
  end
end
