module ChatSpeechToText
  module Providers
    def self.configured(user: nil)
      candidates = provider_classes.select(&:available?)
      pinned_provider_key = ENV["SYRUS_STT_PROVIDER"].to_s.strip.presence
      candidates = candidates.select { |provider| provider.provider_key == pinned_provider_key } if pinned_provider_key

      candidates.filter_map { |provider| provider.build(user: user) }.first
    end

    def self.provider_classes
      Syrus::PluginRegistry.providers_for(:speech_to_text_provider).map do |provider|
        provider.is_a?(String) ? provider.constantize : provider
      end
    end
  end
end
