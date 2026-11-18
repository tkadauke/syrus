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
        manifests.flat_map do |manifest|
          entries_for(manifest).filter_map do |entry|
            declaration = ProviderDeclaration.build(plugin_name: manifest.name, attributes: entry)
            if seen.key?(declaration.key)
              reject!(manifest, "connected_accounts provider key #{declaration.key.inspect} is already declared by #{seen[declaration.key]}")
              next
            end
            seen[declaration.key] = manifest.name
            declaration
          rescue ArgumentError => error
            reject!(manifest, "invalid connected_accounts provider: #{error.message}")
            nil
          end
        end
      end

      def manifests
        return [] unless Syrus::PluginRegistry.extension_point?(EXTENSION_POINT)

        Syrus::PluginRegistry.all_plugins.select(&:enabled?)
      end

      def entries_for(manifest)
        Array(manifest.provides[EXTENSION_POINT] || manifest.provides[EXTENSION_POINT.to_sym])
      end

      def reject!(manifest, message)
        Syrus::PluginRegistry.add_validation_error(manifest.name, message)
      end
    end
  end
end
