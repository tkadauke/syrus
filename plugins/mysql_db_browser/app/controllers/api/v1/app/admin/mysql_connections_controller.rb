module Api
  module V1
    module App
      module Admin
        class MysqlConnectionsController < BaseController
          before_action :require_mysql_db_browser_enabled

          def index
            render json: { mysql_connections: MysqlConnection.order(:label).map { |connection| connection_json(connection) } }
          end

          def create
            connection = MysqlConnection.new(connection_params)
            connection.password = params.dig(:mysql_connection, :password) if params.dig(:mysql_connection, :password).present?

            if connection.save
              render json: { mysql_connection: connection_json(connection) }, status: :created
            else
              render_error("validation_failed", connection.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def update
            connection = find_connection
            connection.assign_attributes(connection_params)
            connection.password = params.dig(:mysql_connection, :password) if params.dig(:mysql_connection, :password).present?

            if connection.save
              render json: { mysql_connection: connection_json(connection) }
            else
              render_error("validation_failed", connection.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          end

          def destroy
            find_connection.destroy!
            head :no_content
          end

          def test_connection
            result = if params[:id].present?
              test_existing_connection
            else
              test_draft_connection
            end

            render json: result
          end

          private

          def test_existing_connection
            connection = find_connection
            password = params.dig(:mysql_connection, :password).presence || connection.password

            ::MysqlDbBrowser::ConnectionTester.test_params(
              host: connection.host,
              port: connection.port,
              username: connection.username,
              password: password,
              database: connection.default_database
            )
          end

          def test_draft_connection
            attrs = connection_params
            ::MysqlDbBrowser::ConnectionTester.test_params(
              host: attrs[:host],
              port: attrs[:port],
              username: attrs[:username],
              password: params.dig(:mysql_connection, :password),
              database: attrs[:default_database]
            )
          end

          def find_connection
            MysqlConnection.find(params[:id])
          end

          def connection_params
            params.require(:mysql_connection).permit(:label, :host, :port, :username, :default_database, :agentic_access_enabled)
          end

          def connection_json(connection)
            {
              id: connection.id,
              label: connection.label,
              host: connection.host,
              port: connection.port,
              username: connection.username,
              default_database: connection.default_database,
              agentic_access_enabled: connection.agentic_access_enabled,
              has_password: connection.password.present?,
              created_at: connection.created_at.iso8601,
              updated_at: connection.updated_at.iso8601
            }
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
