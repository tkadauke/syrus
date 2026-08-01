module App
  module ExternalPlatforms
    class Base
      def self.key = name.demodulize.underscore

      def self.label = key.titleize

      def self.configured? = false

      def self.linking_instructions(_token) = { text: "This platform is not yet configured." }
    end

    class Telegram < Base
      def self.configured?
        AppSetting.telegram_configured?
      end

      def self.linking_instructions(token)
        bot_handle = AppSetting.telegram_bot_handle
        { text: "Send /start #{token} to @#{bot_handle} on Telegram", bot_handle: bot_handle }
      end
    end

    class Slack < Base
    end

    PLATFORMS = [
      Telegram,
      Slack
    ].freeze

    def self.all = PLATFORMS

    def self.names = PLATFORMS.map(&:key)

    def self.fetch(platform)
      PLATFORMS.index_by(&:key).fetch(platform.to_s)
    end

    def self.include?(platform)
      names.include?(platform.to_s)
    end
  end
end
