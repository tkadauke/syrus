module ConnectedAccounts
  module ProviderRegistry
    EXTENSION_POINT = "connected_accounts:provider"

    class << self
      def load!
        declarations
      end

      def all
        declarations
      end

      def fetch(key)
        all.index_by(&:key).fetch(key.to_s)
      end

      private

      def declarations
        seen = {}
        contributions.filter_map do |plugin_name, entry|
          declaration = ProviderDeclaration.build(plugin_name: plugin_name, attributes: entry)
          if seen.key?(declaration.key)
            reject!(plugin_name, "connected_accounts provider key #{declaration.key.inspect} is already declared by #{seen[declaration.key]}")
            next
          end
          seen[declaration.key] = plugin_name
          declaration
        rescue ArgumentError => error
          reject!(plugin_name, "invalid connected_accounts provider: #{error.message}")
          nil
        end
      end

      # Contributions from plugins that are enabled *and* healthy, with the
      # plugin that made each one. Reading manifests with enabled? alone kept
      # a degraded or failed contributor's OAuth provider live (NY18).
      def contributions
        return [] unless Syrus::PluginRegistry.extension_point?(EXTENSION_POINT)

        Syrus::PluginRegistry.providers_with_owner_for(EXTENSION_POINT)
      end

      def reject!(plugin_name, message)
        Syrus::PluginRegistry.add_validation_error(plugin_name, message)
      end
    end
  end
end
