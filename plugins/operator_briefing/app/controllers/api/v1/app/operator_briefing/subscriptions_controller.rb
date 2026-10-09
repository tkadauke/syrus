module Api
  module V1
    module App
      module OperatorBriefing
        class SubscriptionsController < BaseController
          def update
            subscription = ::OperatorBriefing::BriefingSubscription
              .where(user: Current.user, repository_id: Repository.accessible_repository_ids_for(Current.user))
              .find(params[:id])
            subscription.update!(enabled: ActiveModel::Type::Boolean.new.cast(subscription_params.fetch(:enabled)))
            ::OperatorBriefing::OptOutCleanup.cancel_for_subscription!(subscription) unless subscription.enabled?

            render json: ::OperatorBriefing::Payload.new(user: Current.user).as_json
          end

          private

          def subscription_params
            params.require(:subscription).permit(:enabled)
          end
        end
      end
    end
  end
end
