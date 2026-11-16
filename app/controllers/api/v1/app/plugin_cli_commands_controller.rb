module Api
  module V1
    module App
      class PluginCliCommandsController < BaseController
        def index
          payload = { commands: PluginCliCommands.catalog }
          response.headers["Cache-Control"] = "private, max-age=60"
          fresh_when(etag: payload, public: false)
          render json: payload unless performed?
        end

        def create
          result = PluginCliCommands.execute(
            plugin: params[:plugin],
            path: params[:path],
            args: params[:args],
            flags: params[:flags] || {},
            user: Current.user
          )
          render json: { result: result.as_json }
        rescue PluginCliCommands::ValidationError => e
          render_error(e.message, I18n.t("api.plugin_cli_commands.errors.#{e.message}"), status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", I18n.t("api.base.admin_forbidden"), status: :forbidden)
        rescue StandardError => e
          Rails.error.report(e, handled: true, context: { plugin: params[:plugin], command_path: params[:path] })
          render_error("handler_failed", I18n.t("api.plugin_cli_commands.errors.handler_failed"), status: :internal_server_error)
        end
      end
    end
  end
end
