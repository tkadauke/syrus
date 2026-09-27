module Api
  module V1
    module App
      module OperatorBriefing
        class SourcePreferencesController < BaseController
          def update
            preference = ::OperatorBriefing::SourcePreference.where(user: Current.user).find(params[:id])

            ::OperatorBriefing::SourcePreference.create!(
              user: Current.user,
              source_key: preference.source_key,
              enabled: ActiveModel::Type::Boolean.new.cast(source_preference_params.fetch(:enabled)),
              weight: source_preference_params[:weight].presence || preference.weight,
              suggested_by: "user",
              confirmed_at: Time.current
            )

            render json: ::OperatorBriefing::Payload.new(user: Current.user).as_json
          end

          def confirm
            preference = ::OperatorBriefing::SourcePreference.pending_for_user(Current.user).find(params[:id])
            preference.confirm!

            render json: ::OperatorBriefing::Payload.new(user: Current.user).as_json
          end

          private

          def source_preference_params
            params.require(:source_preference).permit(:enabled, :weight)
          end
        end
      end
    end
  end
end
