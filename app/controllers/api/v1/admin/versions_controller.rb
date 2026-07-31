module Api
  module V1
    module Admin
      # Reports the running git SHA + role of every live Rails
      # process (web + worker pods) registered in instance_versions.
      # See InstanceVersionSupervisor for the heartbeat/registration
      # lifecycle that populates the table.
      class VersionsController < BaseController
        def index
          fresh_instances = InstanceVersion.fresh.order(:role, :hostname).to_a

          render json: {
            request_handler: {
              hostname: SyrusVersion.hostname,
              role: SyrusVersion.role,
              version: SyrusVersion.current
            },
            instances: fresh_instances.map { |iv| serialize(iv) },
            worker_health: ::Admin::WorkerHealthPayload.new(sample_limit_per_host: 4).as_json
          }
        end

        private

        def serialize(instance)
          {
            id: instance.id,
            hostname: instance.hostname,
            role: instance.role,
            version: instance.version,
            started_at: instance.started_at&.iso8601,
            last_heartbeat_at: instance.last_heartbeat_at&.iso8601,
            seconds_since_heartbeat: instance.seconds_since_heartbeat,
            stale: instance.stale?,
            data_root_usage: instance.data_root_usage_json
          }
        end
      end
    end
  end
end
