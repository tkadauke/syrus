module Api
  module V1
    module App
      module Admin
        class PluginInstallerController < BaseController
          rescue_from PluginInstaller::Error, ArgumentError do |error|
            render_error("invalid_plugin_package", error.message, status: :unprocessable_content)
          end

          def index = render(json: payload)

          def stage
            change = installer.stage_archive!(params.require(:archive), signature: params[:signature])
            render json: serialize_change(change), status: :created
          end

          def stage_remove
            change = installer.stage_remove!(params.require(:name))
            render json: serialize_change(change), status: :created
          end

          def confirm
            change = installer.confirm!(PluginChange.pending.find(params[:id]))
            render json: { change: serialize_change(change), restart_required: true, apply_path: "/api/v1/admin/plugin_desired_state/apply" }
          end

          def export_lockfile
            send_data PluginLockfile.export, filename: "syrus-plugins.lock.yml", type: "application/yaml"
          end

          def import_lockfile
            changes = PluginLockfile.import!(params.require(:lockfile).read, actor: Current.user)
            render json: { changes: changes.map { |change| serialize_change(change) } }, status: :created
          end

          private

          def installer = PluginInstaller.new(actor: Current.user)

          def payload
            {
              installations: PluginInstallation.includes(:plugin_release).order(:plugin_name).map { |installation| serialize_installation(installation) },
              pending_changes: PluginChange.pending.includes(:plugin_release).order(:created_at).map { |change| serialize_change(change) }
            }
          end

          def serialize_installation(installation)
            release = installation.plugin_release
            record = PluginRecord.find_by(name: installation.plugin_name)
            health = record ? (record.last_error_at? ? "degraded" : "healthy") : "pending_restart"
            { name: installation.plugin_name, version: release.version, release_id: release.id, source: release.source,
              trust_label: release.trust_label, digest: release.content_digest, health: }
          end

          def serialize_change(change)
            previous = PluginInstallation.find_by(plugin_name: change.plugin_name)&.plugin_release
            current = change.plugin_release
            before = previous ? capability_manifest(previous) : {}
            after = change.remove? ? {} : change.capability_manifest
            { id: change.id, name: change.plugin_name, action: change.action, status: change.status,
              version: current&.version, source: current&.source, trust_label: current&.trust_label,
              capability_manifest: after, capability_diff: manifest_diff(before, after) }
          end

          def capability_manifest(release)
            PluginChange.where(plugin_release: release, status: "confirmed").order(:confirmed_at).last&.capability_manifest || {}
          end

          def manifest_diff(before, after)
            (before.keys | after.keys).index_with do |key|
              old_values, new_values = Array(before[key]), Array(after[key])
              { added: new_values - old_values, removed: old_values - new_values }
            end
          end
        end
      end
    end
  end
end
