module Syrus
  module PluginPackage
    class RevocationReconciler
      def initialize(trust_store, plugin_registry: nil)
        @trust_store = trust_store
        @plugin_registry = plugin_registry
      end

      def call
        installations = PluginInstallation.includes(:plugin_release)
        installations = installations.where(plugin_releases: { plugin_registry_id: @plugin_registry&.id })
        revoked_installations = installations.find_each.filter_map do |installation|
          installation if @trust_store.revoked?(installation.plugin_release)
        end
        return [] if revoked_installations.empty?

        PluginInstallation.where(id: revoked_installations.map(&:id), fleet_quarantined: false)
          .update_all(fleet_quarantined: true, updated_at: Time.current)
        PluginDesiredState::Publisher.publish!
        revoked_installations
      end
    end
  end
end
