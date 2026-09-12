module Api
  module V1
    module App
      class JobCodingModeController < BaseController
        def open
          unless Feature.coding_mode_enabled?
            render_error("feature_disabled", "Coding Mode is not enabled on this instance.", status: :unprocessable_content)
            return
          end

          job = find_job
          result = JobCodingMode::Takeover.call(job: job, user: Current.user)

          render json: { redirect_to: "/chats/#{result.chat_session.id}" }
        rescue ActiveRecord::RecordNotFound
          raise
        rescue JobCodingMode::Takeover::Error => e
          render_error("validation_failed", e.message, status: :unprocessable_content)
        rescue StandardError => e
          render_error("server_error", "Could not open Job in Coding Mode: #{e.message}", status: :internal_server_error)
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs.includes(:repository), params[:job_id])
        end
      end
    end
  end
end
