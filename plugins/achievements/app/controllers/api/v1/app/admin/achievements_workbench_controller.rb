module Api
  module V1
    module App
      module Admin
        class AchievementsWorkbenchController < Syrus::Host::AppAdminController
          before_action :require_admin
          before_action :require_workbench

          def show
            render json: Achievements::Workbench.catalog
          end

          private

          def require_workbench
            return if Achievements::Workbench.available?

            render_error("workbench_unavailable", I18n.t("achievements.api.workbench_unavailable"), status: :not_found)
          end
        end
      end
    end
  end
end
