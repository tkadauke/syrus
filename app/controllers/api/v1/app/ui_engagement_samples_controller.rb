module Api
  module V1
    module App
      class UiEngagementSamplesController < BaseController
        def create
          return head :no_content unless AppSetting.ui_engagement_telemetry_enabled?

          sample = Current.user.ui_engagement_samples.new(sample_params)
          if sample.save
            head :accepted
          else
            render_error("validation_failed", sample.errors.full_messages.to_sentence, status: :unprocessable_content)
          end
        end

        private

        def sample_params
          params.expect(ui_engagement_sample: [ :route_id, :started_at, :ended_at, :active_ms, :visible_ms, route_params: %i[job_id repository_id chat_id] ])
        end
      end
    end
  end
end
