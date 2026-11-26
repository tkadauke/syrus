module Api
  module V1
    module App
      # Per-user view of achievements. Exposes definition metadata and unlock and
      # acknowledgment timestamps, plus an evidence link only to a Job or Epic the
      # caller can access. Raw evidence and subject ids are never returned, and
      # another user's unlocks are not visible at all.
      class AchievementsController < Syrus::Host::AppController
        rescue_from Achievements::Reveals::NotFound do
          render_error("not_found", I18n.t("achievements.api.not_found"), status: :not_found)
        end

        def index
          listing = reveals.listing
          links = reveals.evidence_links(listing.map(&:first))
          render json: {
            achievements: listing.map { |unlock, acked_at| unlock_json(unlock, acked_at, links[unlock.id]) },
            locked: reveals.locked.map { |definition| locked_json(definition) }
          }
        end

        def pending
          unlocks = if params[:subject_type].present?
            reveals.pending_for_subject(params[:subject_type], params[:subject_id])
          else
            reveals.pending
          end
          render json: { achievements: unlocks.map { |unlock| unlock_json(unlock, nil) } }
        end

        def acknowledge
          unlock = reveals.acknowledge!(params[:id])
          render json: { achievement: unlock_json(unlock, unlock.acknowledgments.find_by(user_id: Syrus::Host::Current.user.id)&.acknowledged_at, reveals.evidence_links([ unlock ])[unlock.id]) }
        end

        def replay
          unlock = reveals.replay!(params[:id])
          render json: { achievement: unlock_json(unlock, nil, reveals.evidence_links([ unlock ])[unlock.id]) }
        end

        def reset_acknowledgments
          render json: { reset: reveals.reset_own! }
        end

        private

        def reveals = @reveals ||= Achievements::Reveals.new(Syrus::Host::Current.user)

        # Hidden definitions that are still locked carry only their scope.
        def locked_json(definition)
          return { hidden: true, scope: definition.scope } if definition.hidden?

          { hidden: false, key: definition.key, scope: definition.scope, category: definition.category,
            rarity: definition.rarity, presentation: definition.presentation }
        end

        def unlock_json(unlock, acknowledged_at, evidence_link = nil)
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
            acknowledged_at: acknowledged_at&.iso8601,
            evidence_link: evidence_link
          }
        end
      end
    end
  end
end
