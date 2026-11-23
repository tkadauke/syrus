module Discord
  # Linking instructions for Discord's Connected Platforms entry. Wired up
  # via Discord::PlatformAdapter.platform_config_class, which
  # PlatformIdentity::PlatformConfig::Base.for consults for platforms
  # registered through the :platform_delivery extension point.
  class PlatformConfig < PlatformIdentity::PlatformConfig::Base
    def configured?
      Discord::BotAccess.configured?
    end

    def instructions(token)
      { text: "Send /link #{token} to the Syrus bot on Discord" }
    end
  end
end
