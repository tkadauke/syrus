module Syrus
  module PluginPackage
    class RevocationReconciler
      def initialize(trust_store)
        @trust_store = trust_store
      end

      def call
        PluginInstallation.includes(:plugin_release).find_each.filter_map do |installation|
          release = installation.plugin_release
          next unless @trust_store.revoked?(release)

          installation.update!(fleet_quarantined: true) unless installation.fleet_quarantined?
          installation
        end
      end
    end
  end
end
