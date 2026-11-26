module Telegram
  # Linking instructions for Telegram's Connected Platforms entry. Wired up
  # via Telegram::PlatformAdapter.platform_config_class, which
  # PlatformIdentity::PlatformConfig::Base.for consults for platforms
  # registered through the :platform_delivery extension point.
  class PlatformConfig < Syrus::Host::PlatformConfigBase
    def configured?
      Telegram::BotAccess.configured?
    end

    def instructions(token)
      bot_handle = Telegram::BotAccess.handle
      {
        text: "Send /start #{token} to @#{bot_handle} on Telegram",
        bot_handle: bot_handle
      }
    end
  end
end
