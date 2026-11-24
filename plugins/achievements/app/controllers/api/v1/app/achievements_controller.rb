module Api
  module V1
    module App
      # Per-user view of achievements. Exposes definition metadata and unlock and
      # acknowledgment timestamps only: evidence and subject references can name
      # records the caller cannot access, and another user's unlocks are not
      # visible at all.
      class AchievementsController < BaseController
        rescue_from Achievements::Reveals::NotFound do
          render_error("not_found", I18n.t("achievements.api.not_found"), status: :not_found)
        end

        def index
          render json: { achievements: reveals.listing.map { |unlock, acked_at| unlock_json(unlock, acked_at) } }
        end

        def pending
          render json: { achievements: reveals.pending.map { |unlock| unlock_json(unlock, nil) } }
        end

        def acknowledge
          unlock = reveals.acknowledge!(params[:id])
          render json: { achievement: unlock_json(unlock, unlock.acknowledgments.find_by(user_id: Current.user.id)&.acknowledged_at) }
        end

        def replay
          unlock = reveals.replay!(params[:id])
          render json: { achievement: unlock_json(unlock, nil) }
        end

        def reset_acknowledgments
          render json: { reset: reveals.reset_own! }
        end

        private

        def reveals = @reveals ||= Achievements::Reveals.new(Current.user)

        def unlock_json(unlock, acknowledged_at)
          definition = reveals.definition_for(unlock)
          {
            id: unlock.id,
            key: unlock.definition_key,
            version: unlock.definition_version,
            scope: unlock.scope,
            category: definition.category,
            rarity: definition.rarity,
            visibility: definition.visibility,
            presentation: definition.presentation,
            unlocked_at: unlock.unlocked_at.iso8601,
            acknowledged: acknowledged_at.present?,
            acknowledged_at: acknowledged_at&.iso8601
          }
        end
      end
    end
  end
end
