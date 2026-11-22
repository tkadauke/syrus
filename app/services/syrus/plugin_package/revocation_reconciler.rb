module Syrus
  module PluginPackage
    class RevocationReconciler
      def initialize(trust_store)
        @trust_store = trust_store
      end

      def call
        PluginInstallation.includes(:plugin_release).find_each.filter_map do |installation|
          release = installation.plugin_release
          revoked = release.publisher_key_fingerprint.present? && @trust_store.revoked_keys.include?(release.publisher_key_fingerprint.downcase)
          revoked ||= @trust_store.revoked_release?(name: release.name, version: release.version, digest: release.content_digest)
          next unless revoked

          installation.update!(fleet_quarantined: true) unless installation.fleet_quarantined?
          installation
        end
      end
    end
  end
end
