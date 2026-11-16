# frozen_string_literal: true

module Api
  module V1
    module App
      class PluginCliCommandsController < BaseController
        rescue_from Pundit::NotAuthorizedError do
          render_error("forbidden", I18n.t("api.plugin_cli_commands.forbidden"), status: :forbidden)
        end

        def index
          commands = catalog
          fresh_when(etag: Digest::SHA256.hexdigest(commands.to_json), public: false)
          render json: { commands: commands } unless performed?
        end

        def execute
          manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == params.require(:plugin).to_s }
          return render_error("unknown_plugin", I18n.t("api.plugin_cli_commands.unknown_plugin"), status: :not_found) unless manifest
          return render_error("plugin_disabled", I18n.t("api.plugin_cli_commands.plugin_disabled"), status: :conflict) unless executable?(manifest)

          command = manifest.cli_commands.find { |entry| entry.fetch("path") == normalized_path }
          return render_error("unknown_command", I18n.t("api.plugin_cli_commands.unknown_command"), status: :not_found) unless command

          args, flags = Syrus::Plugin::CliCommand.coerce(command, args: parameter_hash(:args), flags: parameter_hash(:flags))
          result = command.fetch("handler").constantize.new.call(args: args, flags: flags, user: Current.user)
          unless result.is_a?(Syrus::Plugin::CliCommandHandler::Result)
            raise TypeError, "CLI command handlers must return Syrus::Plugin::CliCommandHandler::Result"
          end

          render json: { result: result.as_json }
        rescue ArgumentError, ActionController::BadRequest => e
          render_error("invalid_arguments", I18n.t("api.plugin_cli_commands.invalid_arguments", error: e.message), status: :unprocessable_content)
        rescue Pundit::NotAuthorizedError
          raise
        rescue StandardError => e
          Rails.logger.error("[PluginCliCommand] #{params[:plugin]} #{normalized_path}: #{e.class}: #{e.message}")
          render_error("handler_error", I18n.t("api.plugin_cli_commands.handler_error"), status: :internal_server_error)
        end

        private

        def catalog
          Syrus::PluginRegistry.all_plugins.select { |manifest| executable?(manifest) }
            .sort_by(&:name)
            .flat_map do |manifest|
              manifest.cli_commands.sort_by { |command| command.fetch("path") }.map do |command|
                command.except("handler").merge("plugin" => manifest.name)
              end
            end
        end

        def executable?(manifest)
          manifest.enabled? && Syrus::PluginRegistry.health.healthy?(manifest.name)
        end

        def normalized_path
          Array(params.require(:path)).flat_map { |part| part.to_s.split }.join(" ")
        end

        def parameter_hash(key)
          value = params.fetch(key, {})
          value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value.to_h
        end
      end
    end
  end
end
