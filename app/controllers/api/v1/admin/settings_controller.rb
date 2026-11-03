module Api
  module V1
    module Admin
      # Read-only view of the instance AppSetting values, so operator-relevant
      # execution gates such as `max_concurrent_agent_runs` do not have to be
      # scraped from the Prometheus endpoint. Secrets are never returned.
      #
      #   GET /api/v1/admin/settings
      class SettingsController < BaseController
        def show
          settings = AppSetting.current
          definitions = AppSettingRegistry.definitions.reject(&:secret)

          render json: {
            settings: definitions.index_by { |definition| definition.key.to_s }.transform_values do |definition|
              definition.as_json.merge(value: settings.public_send(definition.key))
            end
          }
        end
      end
    end
  end
end
