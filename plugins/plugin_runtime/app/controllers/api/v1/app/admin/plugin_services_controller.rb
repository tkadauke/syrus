module Api
  module V1
    module App
      module Admin
        # The Plugin Services admin page: list plugin containers, stop, start,
        # restart them, and read their logs.
        class PluginServicesController < BaseController
          DETAILS_PER_PAGE = 100
          before_action :require_plugin_runtime, except: :index

          def index
            builder = ::PluginRuntime::AdminPayload.new
            payload = params[:view] == "volumes" ? builder.volumes_json : builder.as_json
            render json: payload if stale?(etag: payload, public: false)
          end

          def stop = act(:stop!)
          def start = act(:start!)
          def restart = act(:restart!)

          def logs
            cursor = Time.current.iso8601(6)
            text = controls.logs(
              params[:name], tail: params[:tail].presence || ::PluginRuntime::Controls::DEFAULT_LOG_TAIL,
              since: params[:since].presence
            )
            render json: { service: params[:name], logs: text, cursor: cursor }
          rescue ::PluginRuntime::Controls::Error, ::PluginRuntime::Client::Error => e
            render_control_error(e)
          end

          # The service's own description of itself (PluginRuntime::Service
          # service_details), for the page's Details panel.
          def details
            entry = (::PluginRuntime::DesiredServices.all + ::PluginRuntime::DesiredPrivilegedServices.all)
              .find { |candidate| candidate.name == params[:name] }
            unless entry&.provider.respond_to?(:service_details)
              return render_error("not_found", "#{params[:name]} has no details", status: :not_found)
            end

            endpoint = ::PluginRuntime::Services.endpoint_for(entry.name)
            details = endpoint && entry.provider.service_details(endpoint: endpoint)
            return render_error("runtime_unavailable", "#{entry.name} is not answering", status: :service_unavailable) unless details

            render json: { service: entry.name, details: paginate_details(details) }
          end

          def remove_volume
            controls.remove_volume!(params[:name])
            head :no_content
          rescue ::PluginRuntime::Controls::Error, ::PluginRuntime::Client::Error => e
            render_control_error(e)
          end

          private

          def paginate_details(details)
            table = details[:table] || details["table"]
            rows = table && (table[:rows] || table["rows"])
            return details unless rows

            total = rows.length
            total_pages = (total.to_f / DETAILS_PER_PAGE).ceil
            page = [ [ params[:page].to_i, 1 ].max, [ total_pages, 1 ].max ].min
            copy = details.deep_dup
            copy_table = copy[:table] || copy["table"]
            rows_key = copy_table.key?(:rows) ? :rows : "rows"
            pagination_key = copy.key?(:table) ? :pagination : "pagination"
            copy_table[rows_key] = rows.slice((page - 1) * DETAILS_PER_PAGE, DETAILS_PER_PAGE) || []
            copy[pagination_key] = { page: page, per_page: DETAILS_PER_PAGE, total: total, total_pages: total_pages }
            copy
          end

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
            when ::PluginRuntime::Client::Conflict then [ "volume_in_use", :conflict ]
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
