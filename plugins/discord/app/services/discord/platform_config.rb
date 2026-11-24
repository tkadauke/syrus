module Discord
  # Linking instructions for Discord's Connected Platforms entry. Wired up
  # via Discord::PlatformAdapter.platform_config_class, which
  # Syrus::Host::PlatformConfigBase.for consults for platforms
  # registered through the :platform_delivery extension point.
  class PlatformConfig < Syrus::Host::PlatformConfigBase
    def configured?
      AppSetting.discord_bot_token.present?
    end

    def instructions(token)
      { text: "Send /link #{token} to the Syrus bot on Discord" }
    end
  end
end
