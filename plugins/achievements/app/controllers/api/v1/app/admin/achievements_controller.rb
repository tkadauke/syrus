module Api
  module V1
    module App
      module Admin
        class AchievementsController < Syrus::Host::AppAdminController
          before_action :require_admin

          # Clears every user's acknowledgments so reveals play again. Needs an
          # explicit confirmation token; unlocks are never touched.
          def reset_acknowledgments
            unless params[:confirm] == Achievements::Reveals::CONFIRM_RESET_ALL
              return render_error("confirmation_required", I18n.t("achievements.api.confirmation_required"), status: :unprocessable_content)
            end

            render json: { reset: Achievements::Reveals.reset_all!(confirmation: params[:confirm]) }
          end
        end
      end
    end
  end
end
