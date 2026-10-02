module SlugRefs
  class Resolver
    def self.resolve(slug, user:)
      new(user: user).resolve(slug)
    end

    def initialize(user:)
      @user = user
    end

    def resolve(slug)
      text = slug.to_s.strip
      return Resolution.malformed if text.blank?

      provider = providers.find { |candidate| candidate.claims?(text) }
      return Resolution.unknown unless provider

      provider.resolve(text, user: @user)
    end

    private

    def providers
      Syrus::PluginRegistry.providers_for(:slug_type)
    end
  end
end
