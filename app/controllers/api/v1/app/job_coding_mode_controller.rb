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

          unless job.implemented? || job.approved?
            render_error("validation_failed", "Only implemented or approved Jobs can be opened in Coding Mode.", status: :unprocessable_content)
            return
          end

          unless job.branch_name.present?
            render_error("validation_failed", "Job does not have a branch yet.", status: :unprocessable_content)
            return
          end

          repository = job.repository
          chat_session = nil

          ApplicationRecord.transaction do
            chat_session = find_or_create_linked_chat!(job, repository)

            if job.approved? && job.may_unapprove?
              Job::ApprovalUnapprover.call(job: job, user: Current.user)
            end

            job.update!(linked_chat_id: chat_session.id)
          end

          ChatWorkspace.ensure_job_branch_checkout!(chat_session, repository, job.branch_name)

          render json: { redirect_to: "/chats/#{chat_session.id}" }
        rescue ActiveRecord::RecordNotFound
          raise
        rescue StandardError => e
          render_error("server_error", "Could not open Job in Coding Mode: #{e.message}", status: :internal_server_error)
        end

        private

        def find_job
          find_job_by_ref(Current.user.jobs.includes(:repository), params[:job_id])
        end

        def find_or_create_linked_chat!(job, repository)
          if job.linked_chat_id.present?
            existing = ChatSession.find_by(id: job.linked_chat_id, user_id: Current.user.id)
            return existing if existing
            # Linked chat was deleted or belongs to a different user — create a new one
          end

          title = "Coding: #{job.title}".first(ChatSession::TITLE_MAX_LENGTH)
          ChatSession.create!(user: Current.user, mode: "coding", repository: repository, title: title)
        end
      end
    end
  end
end
