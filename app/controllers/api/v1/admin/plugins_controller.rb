module Api
  module V1
    module Admin
      class PluginsController < BaseController
        def index
          render json: ::Admin::PluginsPayload.new(query: params[:q]).as_json
        end

        def enable
          plugin = find_plugin_record
          plugin.update!(enabled: true)
          render json: ::Admin::PluginsPayload.new.as_json
        end

        def disable
          plugin = find_plugin_record
          manifest = Syrus::PluginRegistry.all_plugins.find { |candidate| candidate.name == plugin.name }
          ::Admin::PluginDisableGuard.ensure_disableable!(manifest) if manifest
          plugin.update!(enabled: false)
          render json: ::Admin::PluginsPayload.new.as_json
        rescue ActiveRecord::RecordInvalid => e
          render_error("plugin_not_disableable", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        rescue ::Admin::PluginDisableGuard::Blocked => e
          render_error("plugin_in_use", e.message, status: :conflict)
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
