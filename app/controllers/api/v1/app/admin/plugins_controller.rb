module Api
  module V1
    module App
      module Admin
        class PluginsController < BaseController
          include AdminPluginCascadeActions

          def index
            render json: ::Admin::PluginsPayload.new(query: params[:q]).as_json
          end

          def show_config
            record = find_plugin_record
            manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == record.name }
            render json: ::Admin::PluginConfigPayload.new(manifest, record).as_json
          end

          def update_config
            record = find_plugin_record
            manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == record.name }
            new_settings = permitted_config_params(manifest)
            current_settings = record.config.to_h["settings"].to_h
            record.config = record.config.to_h.merge("settings" => current_settings.merge(new_settings))
            record.save!
            render json: ::Admin::PluginConfigPayload.new(manifest, record).as_json
          end

          private

          def find_plugin_record
            PluginRecord.find_by!(name: params[:name])
          end

          def permitted_config_params(manifest)
            allowed_keys = Array(manifest&.config_schema)
              .reject { |entry| entry[:type].to_s == "secret_env" }
              .map { |entry| entry[:key].to_s }
            return {} if allowed_keys.empty?

            (params[:config] || {})
              .to_unsafe_h
              .slice(*allowed_keys)
              .stringify_keys
          end
        end
      end
    end
  end
end
