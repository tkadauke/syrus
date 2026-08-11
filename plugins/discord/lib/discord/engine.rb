module SyrusDiscord
  class Engine < ::Rails::Engine
    config.after_initialize do
      Syrus::PluginRegistry.register(
        name:            "discord",
        display_name:    "Discord",
        version:         SyrusDiscord::VERSION,
        description:     "Links Discord accounts and delivers/receives chat messages over a Gateway DM listener.",
        default_enabled: false,
        disableable:     true,
        category:        "platform_delivery",
        provides: { platform_delivery: Discord::PlatformAdapter }
      )
    end
  end
end
