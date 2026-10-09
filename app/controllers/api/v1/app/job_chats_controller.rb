module Api
  module V1
    module App
      # "Chat about this" -- starts (or resumes) the discussion chat
      # permanently linked to a Job via ChatAttachment. Distinct from
      # JobCodingModeController, which links a chat for exclusive Coding Mode
      # ownership of the implement step; this link is a plain conversation
      # and never blocks or takes over the Job.
      class JobChatsController < BaseController
        include ChatLockErrors
        include ChatSessionLifecycle

        def create
          job = find_job
          return unless authorize_job_mutation!(job)

          chat_session = job.discussion_chat
          user_message = nil
          message_text = requested_message(job).presence

          ApplicationRecord.transaction do
            chat_session ||= ChatSession.create!(user: Current.user, repository: job.repository)
            chat_session.chat_attachments.find_or_create_by!(attachable: job)
            user_message = chat_session.messages.create!(
              role: "user",
              content: { "text" => message_text || opening_message(job) },
              sender_user_id: Current.user.id
            )
            chat_session.pin_chat_provider!
          end

          enqueue_chat_title(chat_session, user_message) if user_message && chat_session.messages.where(role: "user").count == 1
          enqueue_chat_turn(chat_session, user_message) if user_message

          render json: { redirect_to: "/chats/#{chat_session.id}" }
        rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked, ActiveRecord::StatementTimeout, SolidQueue::Job::EnqueueError => e
          raise unless transient_chat_lock_error?(e)

          render_temporary_chat_lock_error
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        private

        def find_job
          scope = Current.user&.admin? ? Job.all : policy_scope(Job)
          find_job_by_ref(scope.includes(:repository), params[:job_id])
        end

        def opening_message(job)
          context_card(job)
        end

        def requested_message(job)
          body = params[:message].to_s.strip
          return if body.blank?

          [ context_card(job), body.truncate(8_000) ].join("\n\n")
        end

        def context_card(job)
          [
            "Context: discuss #{job.slug}.",
            "Repository: #{job.repository.slug}.",
            "Title: #{job.issue_title.presence || job.slug}.",
            "State: #{job.state}."
          ].join("\n")
        end
      end
    end
  end
end
