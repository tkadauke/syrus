module Api
  module V1
    module App
      module OperatorBriefing
        class SubscriptionsController < Syrus::Host::AppController
          def update
            subscription = ::OperatorBriefing::BriefingSubscription
              .where(user: Syrus::Host::Current.user, repository_id: Syrus::Host::Repositories.accessible_repository_ids_for(Syrus::Host::Current.user))
              .find(params[:id])
            subscription.update!(enabled: ActiveModel::Type::Boolean.new.cast(subscription_params.fetch(:enabled)))
            ::OperatorBriefing::OptOutCleanup.cancel_for_subscription!(subscription) unless subscription.enabled?

            render json: { subscription: ::OperatorBriefing::Payload.new(user: Syrus::Host::Current.user).subscription_payload(subscription) }
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
