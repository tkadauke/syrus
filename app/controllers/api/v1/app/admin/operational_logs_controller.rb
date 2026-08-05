module Api
  module V1
    module App
      module Admin
        class OperationalLogsController < BaseController
          def index
            render json: OperationalLogging.suppress { ::Admin::OperationalLogsPayload.new(params: params).as_json }
          rescue ArgumentError => e
            render_error("invalid_operational_log_search", e.message, status: :unprocessable_content)
          end
        end
      end
    end
  end
end
