module Api
  module V1
    module App
      # Session-authenticated data API for the Metrics Dashboard page.
      #
      # Admin-only: these are instance-wide operational numbers -- queue depth,
      # failure counts, which plugins are on -- not anything scoped to the
      # requesting user's own work.
      class MetricsDashboardController < BaseController
        before_action :require_metrics_dashboard_enabled
        before_action :require_admin

        def show
          render json: ::MetricsDashboard::DashboardPayload.build(window: params[:window].to_s)
        end

        private

        def require_metrics_dashboard_enabled
          return if ::MetricsDashboard.enabled?

          render_error("plugin_disabled",
                       I18n.t("api.plugins.disabled", plugin: "metrics_dashboard"),
                       status: :not_found)
        end

        def require_admin
          return if Current.user&.admin?

          render_error("forbidden", I18n.t("api.base.admin_required"), status: :forbidden)
        end
      end
    end
  end
end
