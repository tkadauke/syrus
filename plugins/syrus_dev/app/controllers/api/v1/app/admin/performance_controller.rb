module Api
  module V1
    module App
      module Admin
        class PerformanceController < BaseController
          def show
            return render json: { error: "syrus_dev_plugin_disabled" }, status: :not_found unless SyrusDev.enabled?

            render json: PerformanceLogging.suppress { ::SyrusDev::PerformancePayload.new(params: params).as_json }
          end

          def explain
            return render json: { error: "syrus_dev_plugin_disabled" }, status: :not_found unless SyrusDev.enabled?

            result = PerformanceLogging.suppress do
              ::SyrusDev::SqlExplain.call(
                sql: params.require(:sql),
                analyze: params[:analyze],
                timeout_ms: params[:timeout_ms]
              )
            end
            render json: result.as_json
          rescue ::SyrusDev::SqlExplain::Error => e
            render_error("invalid_sql_explain_request", e.message, status: :unprocessable_entity)
          end
        end
      end
    end
  end
end
