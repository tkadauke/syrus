module Api
  module V1
    module App
      module Admin
        class MacosWorkerUpdatesController < BaseController
          skip_before_action :require_admin
          before_action :require_macos_worker_update_access
          after_action :audit_macos_worker_credential

          rescue_from ArgumentError do |e|
            render_error("bad_request", e.message, status: :bad_request)
          end

          def desired
            release = AppSetting.macos_worker_desired_release
            drain = drain_for_request
            render json: desired_payload(release, drain: drain).merge(drain: drain_directive(drain))
          end

          def report
            attrs = status_params
            now = Time.current
            hostname = attrs["hostname"].presence || SyrusVersion.hostname
            current_version = attrs["current_version"].presence || attrs["version"].presence || "unknown"
            desired = attrs["desired"].presence || {}
            status = attrs.except("desired").merge(
              "observed_at" => now.iso8601,
              "reported_by" => "macos_worker_updater"
            )

            instance = InstanceVersion.find_or_initialize_by(hostname: hostname, role: "worker")
            instance.assign_attributes(
              version: current_version,
              desired_version: desired,
              macos_updater_status: status,
              started_at: instance.started_at || now,
              last_heartbeat_at: now
            )
            instance.save!
            sync_drain_identity!(instance, attrs)

            render json: {
              ok: true,
              worker: {
                hostname: instance.hostname,
                version: instance.version,
                desired_version: instance.desired_version || {},
                macos_updater_status: instance.macos_updater_status || {},
                macos_updater_state: instance.macos_updater_state
              }
            }
          end

          def advance
            render json: ::MacosWorkerRollout.advance!.as_json
          end

          def drain
            render json: ::MacosWorkerRollout.drain!(**rollout_identity).as_json
          end

          def clear
            render json: ::MacosWorkerRollout.clear!(**rollout_identity).as_json
          end

          def force_terminate
            render json: ::MacosWorkerRollout.force_terminate!(**rollout_identity).as_json
          end

          private

          def require_macos_worker_update_access
            return true if Current.user&.admin?
            return true if current_invocation_context&.macos_worker?

            render_error("forbidden", I18n.t("api.base.admin_forbidden"), status: :forbidden)
            false
          end

          def audit_macos_worker_credential
            return unless current_invocation_context&.macos_worker?

            OperationalLogging.ingest(
              level: response.status.to_i >= 400 ? "warn" : "info",
              source: "macos_worker_update",
              message: "macOS worker update credential #{response.status.to_i >= 400 ? 'rejected' : 'allowed'}",
              context: {
                method: request.request_method,
                path: request.path,
                action: action_name,
                status: response.status.to_i,
                hostname: params[:hostname].presence || params.dig(:status, :hostname).presence,
                worker_storage_key: params[:worker_storage_key].presence || params.dig(:status, :worker_storage_key).presence
              }.compact
            )
          end

          def desired_payload(release, drain:)
            enabled = release["artifact_url"].present? && release["git_sha"].present? && !!drain&.update_permitted?
            {
              enabled: enabled,
              component: "macos-worker",
              desired: release.slice(
                "version",
                "git_sha",
                "full_git_sha",
                "artifact_url",
                "artifact_sha256",
                "artifact_name",
                "built_at",
                "metadata_url"
              ).compact,
              retention_count: release["retention_count"].presence || 3,
              poll_interval_seconds: release["poll_interval_seconds"].presence || 300
            }
          end

          def drain_for_request
            ::MacosWorkerDrain.for_identity(
              worker_storage_key: params[:worker_storage_key],
              hostname: params[:hostname]
            ).active.first
          end

          def drain_directive(drain)
            drain&.directive_payload || { state: "none" }
          end

          def rollout_identity
            {
              worker_storage_key: params[:worker_storage_key].presence,
              hostname: params[:hostname].presence
            }.compact
          end

          def sync_drain_identity!(instance, attrs)
            key = attrs["worker_storage_key"].presence
            drain = ::MacosWorkerDrain.for_identity(worker_storage_key: key, hostname: instance.hostname).active.first
            return unless drain

            drain.update!(
              worker_storage_key: key || drain.worker_storage_key,
              hostname: instance.hostname
            )
          end

          def status_params
            params.require(:status).permit(
              :hostname,
              :worker_storage_key,
              :pool,
              :state,
              :message,
              :current_version,
              :version,
              :target_version,
              :release_path,
              :previous_release_path,
              :activated_at,
              :failed_at,
              desired: [
                :version,
                :git_sha,
                :full_git_sha,
                :artifact_url,
                :artifact_sha256,
                :artifact_name,
                :built_at,
                :metadata_url
              ]
            ).to_h
          end
        end
      end
    end
  end
end
