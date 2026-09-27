module Api
  module V1
    module App
      module OperatorBriefing
        class BriefingsController < BaseController
          def show
            render json: ::OperatorBriefing::Payload.new(user: Current.user).as_json
          end

          def regenerate
            repository = Repository.where(id: Repository.accessible_repository_ids_for(Current.user)).find(params[:repository_id])
            ::OperatorBriefing::BriefingSubscription.find_or_create_by!(user: Current.user, repository: repository)
            ::OperatorBriefing::Generator.generate!(user: Current.user, repository: repository, mode: :on_demand)

            render json: ::OperatorBriefing::Payload.new(user: Current.user).as_json
          end
        end
      end
    end
  end
end
