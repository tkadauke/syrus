module Api
  module V1
    module App
      module Admin
        # The Plugin Services admin page: list plugin containers, stop, start,
        # restart them, and read their logs.
        class PluginServicesController < BaseController
          before_action :require_plugin_runtime

          def index
            render json: ::PluginRuntime::AdminPayload.new.as_json
          end

          def stop = act(:stop!)
          def start = act(:start!)
          def restart = act(:restart!)

          def logs
            text = controls.logs(params[:name], tail: params[:tail].presence || ::PluginRuntime::Controls::DEFAULT_LOG_TAIL)
            render json: { service: params[:name], logs: text }
          rescue ::PluginRuntime::Controls::Error, ::PluginRuntime::Client::Error => e
            render_control_error(e)
          end

          private

          def act(action)
            status = controls.public_send(action, params[:name])
            render json: { service: status.to_h }
          rescue ::PluginRuntime::Controls::Error, ::PluginRuntime::Client::Error => e
            render_control_error(e)
          end

          def render_control_error(error)
            code, status = case error
            when ::PluginRuntime::Controls::NotManaged then [ "not_managed", :unprocessable_content ]
            when ::PluginRuntime::Controls::UnknownService, ::PluginRuntime::Client::NotFound then [ "not_found", :not_found ]
            when ::PluginRuntime::Client::Refused then [ "refused", :unprocessable_content ]
            else [ "runtime_unavailable", :service_unavailable ]
            end
            render_error(code, error.message, status: status)
          end

          def controls
            @controls ||= ::PluginRuntime::Controls.new
          end

          def require_plugin_runtime
            return if ::PluginRuntime.enabled?

            render_error("plugin_disabled", "Plugin Runtime is disabled.", status: :not_found)
          end
        end
      end
    end
  end
end
