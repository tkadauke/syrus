module Api
  module V1
    module App
      module Admin
        class MysqlController < BaseController
          before_action :require_admin_mysql_enabled

          def show
            render json: PerformanceLogging.suppress {
              ::AdminMysql::Inspector.new.snapshot(limit: params[:limit])
            }
          rescue ::AdminMysql::Inspector::Unavailable => e
            render_error("mysql_unavailable", e.message, status: :unprocessable_entity)
          end

          def kill_query
            render json: PerformanceLogging.suppress {
              ::AdminMysql::Inspector.new.kill_query(params.require(:thread_id))
            }
          rescue ArgumentError => e
            render_error("bad_request", e.message, status: :bad_request)
          rescue ::AdminMysql::Inspector::Unavailable => e
            render_error("mysql_unavailable", e.message, status: :unprocessable_entity)
          end

          private

          def require_admin_mysql_enabled
            return if ::AdminMysql.enabled?

            render_error("plugin_disabled", "The admin_mysql plugin is disabled.", status: :not_found)
          end
        end
      end
    end
  end
end
