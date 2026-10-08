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
          created_chat = false
          requested_message_text = requested_message(job)
          message_text = requested_message_text || reference_message(job)

          ApplicationRecord.transaction do
            unless chat_session
              chat_session = ChatSession.create!(user: Current.user, repository: job.repository)
              created_chat = true
            end
            chat_session.chat_attachments.find_or_create_by!(attachable: job)
            chat_session.pin_chat_provider!
          end

          user_message = create_user_message(chat_session, message_text) if created_chat || requested_message_text

          enqueue_chat_title(chat_session, user_message) if created_chat && user_message
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
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end

        def create_user_message(chat_session, text)
          chat_session.messages.create!(
            role: "user",
            content: { "text" => text },
            sender_user_id: Current.user.id
          )
        end

        def requested_message(job)
          body = params[:message].to_s.strip
          return if body.blank?

          [ reference_message(job), body.truncate(8_000) ].join("\n\n")
        end

        def reference_message(job)
          "Context: discuss #{job.slug}."
        end
      end
    end
  end
end
