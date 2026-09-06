module Api
  module V1
    module App
      # "Chat about this" -- starts (or resumes) the discussion chat
      # permanently linked to a Job via ChatAttachment. Distinct from
      # JobCodingModeController, which links a chat for exclusive Coding Mode
      # ownership of the implement step; this link is a plain conversation
      # and never blocks or takes over the Job.
      class JobChatsController < BaseController
        def create
          job = find_job
          return unless authorize_job_mutation!(job)

          chat_session = job.discussion_chat

          unless chat_session
            ApplicationRecord.transaction do
              chat_session = ChatSession.create!(user: Current.user, repository: job.repository)
              chat_session.chat_attachments.create!(attachable: job)
            end
          end

          render json: { redirect_to: "/chats/#{chat_session.id}" }
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        private

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end
      end
    end
  end
end
