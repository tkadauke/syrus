module Api
  module V1
    module App
      class PluginCliCommandsController < BaseController
        rescue_from PluginCli::Catalog::UnknownPlugin do
          render_cli_error("unknown_plugin", :not_found)
        end
        rescue_from PluginCli::Catalog::DisabledPlugin do
          render_cli_error("disabled_plugin", :not_found)
        end
        rescue_from PluginCli::Catalog::UnknownCommand do
          render_cli_error("unknown_command", :not_found)
        end
        rescue_from Syrus::Plugin::CliCommand::InvalidArguments do |error|
          render_error("invalid_arguments", I18n.t("api.plugin_cli.errors.invalid_arguments", detail: error.message), status: :unprocessable_content)
        end
        rescue_from Pundit::NotAuthorizedError do
          render_cli_error("forbidden", :forbidden)
        end

        def index
          payload = { commands: catalog.commands }
          fresh_when(etag: payload, public: false)
          render json: payload unless performed?
        end

        def execute
          _manifest, command = catalog.find(plugin: params.require(:plugin), path: normalized_path)
          args, flags = PluginCli::ArgumentParser.new(
            command,
            args: params[:args] || {},
            flags: params[:flags] || {}
          ).parse
          result = resolve_handler(command).new.call(args: args, flags: flags, user: Current.user)
          unless result.respond_to?(:as_json) && %w[table text json].include?(result.as_json[:kind])
            raise TypeError, "CLI command handlers must return a Syrus::Plugin::CliCommand result"
          end

          render json: { result: result.as_json }
        rescue PluginCli::Catalog::UnknownPlugin,
               PluginCli::Catalog::DisabledPlugin,
               PluginCli::Catalog::UnknownCommand,
               Syrus::Plugin::CliCommand::InvalidArguments,
               Pundit::NotAuthorizedError
          raise
        rescue StandardError => error
          Rails.error.report(error, handled: true, context: { plugin: params[:plugin], command: params[:path] })
          render_cli_error("handler_error", :internal_server_error)
        end

        private

        def catalog = @catalog ||= PluginCli::Catalog.new
        def normalized_path = Array(params.require(:path)).join(" ").strip.gsub(/\s+/, " ")

        def resolve_handler(command)
          command.fetch("handler").constantize.tap do |handler|
            unless handler.include?(Syrus::Plugin::CliCommand)
              raise TypeError, "#{handler} must include Syrus::Plugin::CliCommand"
            end
          end
        end

        def render_cli_error(code, status)
          render_error(code, I18n.t("api.plugin_cli.errors.#{code}"), status: status)
        end
      end
    end
  end
end
