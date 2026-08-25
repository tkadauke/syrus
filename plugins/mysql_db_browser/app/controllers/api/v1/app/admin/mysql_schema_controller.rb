module Api
  module V1
    module App
      module Admin
        class MysqlSchemaController < BaseController
          before_action :require_mysql_db_browser_enabled
          before_action :set_connection

          def databases
            render json: inspector.databases
          rescue ::MysqlDbBrowser::SchemaInspector::Unavailable => e
            render_error("connection_unavailable", e.message, status: :bad_gateway)
          end

          def tables
            render json: inspector.tables(params[:database])
          rescue ::MysqlDbBrowser::SchemaInspector::Unavailable => e
            render_error("connection_unavailable", e.message, status: :bad_gateway)
          end

          def show
            render json: inspector.table(params[:database], params[:table])
          rescue ::MysqlDbBrowser::SchemaInspector::Unavailable => e
            render_error("connection_unavailable", e.message, status: :bad_gateway)
          rescue ::MysqlDbBrowser::SchemaInspector::NotFound => e
            render_error("not_found", e.message, status: :not_found)
          end

          private

          def inspector
            @inspector ||= ::MysqlDbBrowser::SchemaInspector.new(@connection)
          end

          def set_connection
            @connection = MysqlConnection.find(params[:id])
          end

          def require_mysql_db_browser_enabled
            return if ::MysqlDbBrowser.enabled?

            render_error("plugin_disabled", "The mysql_db_browser plugin is disabled.", status: :not_found)
          end
        end
      end
    end
  end
end
