module Api
  module V1
    module App
      module Admin
        class PluginInstallerController < BaseController
          rescue_from PluginInstaller::Error, ActiveRecord::RecordInvalid, ArgumentError do |error|
            render_error("invalid_plugin_package", error.message, status: :unprocessable_content)
          end

          def index = render(json: payload)

          def catalog
            result = PluginRegistrySearch.new.search(params[:q])
            entries = result.entries
            entries = entries.select { |entry| [ entry.registry_name, entry.registry_id.to_s ].include?(params[:registry]) } if params[:registry].present?
            render json: { configured: true, error: result.errors.values.first, errors: result.errors, stale: result.stale.any?,
              stale_registries: result.stale, entries: entries.map(&:to_h) }
          end

          def registries
            render json: { registries: PluginRegistry.sources.map do |source|
              serialize_registry(source).merge(entry_count: source.id ? PluginRelease.where(plugin_registry_id: source.id).count : 0,
                error: source.configuration_error, stale: false)
            end }
          end

          def create_registry
            registry = PluginRegistry.find_by(url: params.require(:url))
            if registry&.removed_at?
              registry.update!(name: params.require(:name), enabled: true, environment_managed: false,
                removed_at: nil, created_by: Current.user)
            else
              registry = PluginRegistry.create!(name: params.require(:name), url: params.require(:url), enabled: true,
                created_by: Current.user)
            end
            render json: serialize_registry(registry), status: :created
          end

          def update_registry
            registry = PluginRegistry.active.find(params[:id])
            raise PluginInstaller::Error, "environment-provided registries are read-only" if registry.read_only?
            registry.update!(enabled: ActiveModel::Type::Boolean.new.cast(params.require(:enabled)))
            render json: serialize_registry(registry)
          end

          def destroy_registry
            registry = PluginRegistry.active.find(params[:id])
            raise PluginInstaller::Error, "the canonical registry can be disabled but not removed" if registry.canonical?
            raise PluginInstaller::Error, "environment-provided registries are read-only" if registry.read_only?
            registry.update!(enabled: false, removed_at: Time.current)
            head :no_content
          end

          def stage
            change = installer.stage_archive!(params.require(:archive), signature: params[:signature])
            render json: serialize_change(change), status: :created
          end

          def stage_remove
            change = installer.stage_remove!(params.require(:name))
            render json: serialize_change(change), status: :created
          end

          def stage_release
            change = installer.stage_release!(params.require(:name), version: params[:version], registry: params[:registry])
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

          def serialize_registry(source)
            cache = WorkflowWorkspace.data_root.join("plugin-registries", source.cache_key)
            refreshed_at = cache.join("refreshed-at")
            { id: source.id, name: source.name, url: source.url, enabled: source.enabled?, canonical: source.canonical?,
              read_only: source.read_only?, last_refresh_at: refreshed_at.exist? ? refreshed_at.mtime : nil,
              healthy: cache.join("index", "index.json").exist? }
          end

          def payload
            installations = PluginInstallation.includes(:plugin_release).order(:plugin_name).to_a
            records = PluginRecord.where(name: installations.map(&:plugin_name)).index_by(&:name)
            installed_by_name = installations.index_by(&:plugin_name)
            manifests = capability_manifests(PluginRelease.ids)
            {
              installations: installations.map { |installation| serialize_installation(installation, records[installation.plugin_name]) },
              pending_changes: PluginChange.pending.includes(:plugin_release).order(:created_at).map do |change|
                serialize_change(change, installed_by_name:, manifests:)
              end,
              available_releases: PluginRelease.includes(:plugin_registry)
                .where.not(id: installations.map(&:plugin_release_id)).order(:name, :version)
                .reject { |release| Syrus::PluginPackage::TrustStore.for_release(release).revoked?(release) }.map do |release|
                { name: release.name, version: release.version, source: release.source, trust_label: release.trust_label }
              end
            }
          end

          def serialize_installation(installation, record)
            release = installation.plugin_release
            health = record ? (record.last_error_at? ? "degraded" : "healthy") : "pending_restart"
            { name: installation.plugin_name, version: release.version, release_id: release.id, source: release.source,
              trust_label: release.trust_label, digest: release.content_digest, health: }
          end

          def serialize_change(change, installed_by_name: nil, manifests: nil)
            installation = installed_by_name ? installed_by_name[change.plugin_name] : PluginInstallation.find_by(plugin_name: change.plugin_name)
            previous = installation&.plugin_release
            current = change.plugin_release
            before = if previous
              manifests ? manifests.fetch(previous.id, {}) : capability_manifest(previous)
            else
              {}
            end
            after = change.remove? ? {} : change.capability_manifest
            { id: change.id, name: change.plugin_name, action: change.action, status: change.status,
              version: current&.version, source: current&.source, trust_label: current&.trust_label,
              capability_manifest: after, capability_diff: manifest_diff(before, after) }
          end

          def capability_manifest(release)
            PluginChange.where(plugin_release: release, status: "confirmed").order(:confirmed_at).last&.capability_manifest || {}
          end

          def capability_manifests(release_ids)
            PluginChange.where(plugin_release_id: release_ids, status: "confirmed").order(:confirmed_at).each_with_object({}) do |change, result|
              result[change.plugin_release_id] = change.capability_manifest
            end
          end

          def manifest_diff(before, after)
            (before.keys | after.keys).index_with do |key|
              old_values, new_values = Array(before[key]), Array(after[key])
              { added: new_values - old_values, removed: old_values - new_values }
            end.reject { |_key, delta| delta[:added].empty? && delta[:removed].empty? }
          end
        end
      end
    end
  end
end
