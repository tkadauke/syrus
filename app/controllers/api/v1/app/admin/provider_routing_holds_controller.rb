module Api
  module V1
    module App
      module Admin
        class ProviderRoutingHoldsController < BaseController
          def release
            hold = ProviderRoutingHold.active.find(params[:id])
            ProviderRouting::HoldRelease.call(
              hold: hold,
              user: Current.user,
              reason: params.require(:reason),
              override: ActiveModel::Type::Boolean.new.cast(params[:override])
            )
            render json: { provider_routing_hold: serialize(hold.reload) }
          end

          private

          def serialize(hold)
            hold.as_json(only: %i[id workflow_id step_id provider_routing_rule_id status resumption_mode reason condition_evidence matched_scope next_reevaluation_at released_at released_by_user_id release_reason release_kind])
          end
        end
      end
    end
  end
end
