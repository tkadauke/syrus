module Api
  module V1
    module App
      class CliCommandsController < BaseController
        def index
          payload = { commands: PluginCliCommands.catalog.map(&:catalog_payload) }
          fresh_when(etag: payload, public: false)
          render json: payload unless performed?
        end

        def create
          command = PluginCliCommands.find(plugin: params[:plugin], path: params[:path])
          return render_command_error(command) if command.is_a?(PluginCliCommands::Error)

          submitted_flags = params[:flags].respond_to?(:to_unsafe_h) ? params[:flags].to_unsafe_h : params[:flags]
          args, flags = command.validate_inputs(args: params[:args], flags: submitted_flags)
          result = command.handler_class.new.call(args: args, flags: flags, user: Current.user)
          unless result.is_a?(Syrus::Plugin::CliCommandHandler::Result)
            raise TypeError, "CLI command handlers must return a CliCommandHandler result"
          end

          render json: { result: result.as_json }
        rescue Syrus::Plugin::CliCommand::ValidationError => e
          Rails.logger.info("[PluginCliCommands] rejected invalid arguments: #{e.message}")
          render_error("invalid_arguments", I18n.t("api.cli_commands.errors.invalid_arguments"), status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          render_error("forbidden", I18n.t("api.cli_commands.errors.forbidden"), status: :forbidden)
        rescue StandardError => e
          Rails.logger.error("[PluginCliCommands] #{params[:plugin]} #{Array(params[:path]).join(' ')} failed: #{e.class}: #{e.message}")
          render_error("handler_error", I18n.t("api.cli_commands.errors.handler_error"), status: :internal_server_error)
        end

        private

        def render_command_error(error)
          render_error(error.code, error.message, status: error.status)
        end
      end
    end
  end
end
