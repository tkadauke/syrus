module Api
  module V1
    module App
      module Admin
        class MacosWorkerUpdatesController < BaseController
          def desired
            release = AppSetting.macos_worker_desired_release
            render json: desired_payload(release)
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

          private

          def desired_payload(release)
            enabled = release["artifact_url"].present? && release["git_sha"].present?
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
