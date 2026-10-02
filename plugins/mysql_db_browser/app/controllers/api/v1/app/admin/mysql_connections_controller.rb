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
            password = params.dig(:mysql_connection, :password).presence

            if connection.save
              ::MysqlDbBrowser::CredentialMaterial.store!(connection, password, user: Current.user) if password
              render json: { mysql_connection: connection_json(connection) }, status: :created
            else
              render_error("validation_failed", connection.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          rescue ::MysqlDbBrowser::CredentialMaterial::CredentialStoreUnavailable => e
            render_error("plugin_disabled", e.message, status: :not_found)
          end

          def update
            connection = find_connection
            connection.assign_attributes(connection_params)
            password = params.dig(:mysql_connection, :password).presence

            if connection.save
              ::MysqlDbBrowser::CredentialMaterial.store!(connection, password, user: Current.user) if password
              render json: { mysql_connection: connection_json(connection) }
            else
              render_error("validation_failed", connection.errors.full_messages.to_sentence, status: :unprocessable_content)
            end
          rescue ::MysqlDbBrowser::CredentialMaterial::CredentialStoreUnavailable => e
            render_error("plugin_disabled", e.message, status: :not_found)
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
            override_password = params.dig(:mysql_connection, :password).presence
            return test_connection_params(connection, override_password) if override_password

            ::MysqlDbBrowser::CredentialMaterial.with_password(connection, context: admin_credential_context, purpose: "test MySQL connection") do |password, _metadata|
              test_connection_params(connection, password)
            end
          rescue ::MysqlDbBrowser::CredentialMaterial::CredentialStoreUnavailable, CredentialStore::Broker::Error => e
            { success: false, error: e.message }
          end

          def test_connection_params(connection, password)
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

          def admin_credential_context
            McpToolContext.new(surface: MysqlConnection::ADMIN_SURFACE, role: nil, user: Current.user)
          end

          def find_connection
            MysqlConnection.find(params[:id])
          end

          def connection_params
            params.require(:mysql_connection).permit(:label, :host, :port, :username, :default_database, :agentic_access_enabled, :allow_writes)
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
              allow_writes: connection.allow_writes,
              has_password: connection.has_password?,
              created_at: connection.created_at.iso8601,
              updated_at: connection.updated_at.iso8601
            }
          end

          def require_mysql_db_browser_enabled
            return if ::MysqlDbBrowser.enabled?

            render_error("plugin_disabled", I18n.t("api.plugins.disabled", plugin: "mysql_db_browser"), status: :not_found)
          end
        end
      end
    end
  end
end
