module Api
  module V1
    module App
      module OperatorBriefing
        class SourcePreferencesController < Syrus::Host::AppController
          def update
            preference = ::OperatorBriefing::SourcePreference.where(user: Syrus::Host::Current.user).find(params[:id])

            changed_preference = ::OperatorBriefing::SourcePreference.create!(
              user: Syrus::Host::Current.user,
              source_key: preference.source_key,
              enabled: ActiveModel::Type::Boolean.new.cast(source_preference_params.fetch(:enabled)),
              weight: source_preference_params[:weight].presence || preference.weight,
              suggested_by: "user",
              confirmed_at: Time.current
            )

            render json: { source_preference: ::OperatorBriefing::Payload.new(user: Syrus::Host::Current.user).source_preference_payload(changed_preference) }
          end

          def confirm
            preference = ::OperatorBriefing::SourcePreference.pending_for_user(Syrus::Host::Current.user).find(params[:id])
            preference.confirm!

            render json: { source_preference: ::OperatorBriefing::Payload.new(user: Syrus::Host::Current.user).source_preference_payload(preference) }
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
