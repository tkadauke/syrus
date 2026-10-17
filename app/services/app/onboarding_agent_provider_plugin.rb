module App
  # Resolves the one plugin whose manifest declares `provides agent_provider:`
  # for a given provider key, and enables it. This exists so the onboarding
  # Configure Agent modal can auto-enable a provider the operator just
  # connected, without ever accepting an arbitrary client-supplied plugin
  # name -- only a plugin actually wired to that agent_provider key can be
  # flipped on. Enabling delegates to the same cascade-aware service used by
  # admin plugin management.
  class OnboardingAgentProviderPlugin
    def self.enable!(provider)
      new(provider).enable!
    end

    def self.connect!(provider, user:)
      new(provider).connect!(user)
    end

    def initialize(provider)
      @provider = provider.to_s
    end

    def enable!
      record = matching_plugin_record
      return nil unless record

      ::Admin::PluginEnabler.enable!(record)
    end

    def connect!(user)
      record = matching_plugin_record
      return nil unless record

      ActiveRecord::Base.transaction do
        ::Admin::PluginEnabler.enable!(record)
        user.update!(agent_provider: provider)
      end

      record
    end

    private

    attr_reader :provider

    def matching_plugin_record
      manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| agent_provider_key_for(candidate) == provider }
      return nil unless manifest

      PluginRecord.find_by(name: manifest.name)
    end

    def agent_provider_key_for(manifest)
      # Manifest.provides is already resolved to the actual class by
      # Syrus::PluginApi::Definition#resolved_provides at registration time,
      # not the string the plugin's `provides agent_provider: "..."` DSL call
      # used to name it.
      klass = manifest.provides[:agent_provider]
      return nil unless klass

      klass.provider_key
    end
  end
end
