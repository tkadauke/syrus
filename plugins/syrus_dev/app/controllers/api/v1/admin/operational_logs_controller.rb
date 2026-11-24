module Api
  module V1
    module Admin
      class OperationalLogsController < Syrus::Host::AdminController
        def index
          return render json: { error: "syrus_dev_plugin_disabled" }, status: :not_found unless SyrusDev.enabled?

          Syrus::Host::OperationalLogging.enabled_for_instance? # warm the Current cache before suppress
          render json: Syrus::Host::OperationalLogging.suppress { Syrus::Host::OperationalLogsPayload.new(params: params).as_json }
        rescue ArgumentError => e
          render_error("invalid_operational_log_search", e.message, status: :unprocessable_content)
        end
      end
    end
  end
end
