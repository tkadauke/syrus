module Api
  module V1
    module Admin
      class PluginDesiredStatesController < BaseController
        def show
          installations = PluginInstallation.includes(:plugin_release).order(:plugin_name)
          render json: {
            revision: PluginDesiredStateRevision.current,
            plugins: installations.map do |installation|
              release = installation.plugin_release
              {
                name: installation.plugin_name,
                version: release.version,
                digest: release.content_digest,
                size: release.size_bytes,
                source: release.source,
                trust_label: release.trust_label,
                roles: installation.roles,
                enabled_for_sync: installation.enabled_for_sync,
                fleet_quarantined: installation.fleet_quarantined,
                desired_since: installation.desired_since
              }
            end
          }
        end
      end
    end
  end
end
