module SyrusDiscord
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "discord",
        display_name:    "Discord",
        version:         SyrusDiscord::VERSION,
        description:     "Links Discord accounts and delivers/receives chat messages over a Gateway DM listener.",
        long_description: "Discord adds a platform-delivery channel for Syrus chat. It links Discord users to Syrus accounts, listens for direct messages through the Gateway, and delivers chat replies back to Discord so operators can interact with Syrus away from the web UI.\n\nThe plugin is disabled by default because it requires Discord credentials and a running Gateway connection. Once configured, it behaves as another chat surface rather than a separate automation engine.",
        homepage:        "https://github.com/tkadauke/syrus",
        icon_url:        "/plugin-icons/discord.svg",
        author:          "Thomas Kadauke",
        default_enabled: false,
        disableable:     true,
        category:        "platform_delivery",
        provides: { platform_delivery: Discord::PlatformAdapter }
      )
    end
  end
end
