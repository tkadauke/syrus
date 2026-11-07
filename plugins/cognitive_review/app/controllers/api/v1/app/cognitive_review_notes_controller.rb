module Api
  module V1
    module App
      class CognitiveReviewNotesController < BaseController
        include ChatLockErrors
        include ChatSessionLifecycle

        def show
          job = find_job
          note = find_note(job)
          render json: { note: note_json(note, include_detail: true) }
        end

        def acknowledge
          job = find_job
          return unless authorize_job_mutation!(job)

          note = find_note(job)
          note.acknowledge!(user: Current.user)
          render json: { note: note_json(note) }
        end

        def create_discussion_entry
          job = find_job
          return unless authorize_job_mutation!(job)

          note = find_note(job)
          note.add_discussion_entry!(
            user: Current.user,
            body: params.require(:body),
            metadata: plain_json(params[:metadata] || {})
          )
          render json: { note: note_json(note.reload) }, status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        def start_discussion
          job = find_job
          return unless authorize_job_mutation!(job)

          note = find_note(job)
          chat_session = nil
          user_message = nil
          previous_state = note.state

          ApplicationRecord.transaction do
            started_discussion = note.start_discussion!(user: Current.user)
            chat_session = discussion_chat_for(job)
            if started_discussion
              user_message = chat_session.messages.create!(
                role: "user",
                content: { "text" => discussion_message(job, note, previous_state: previous_state) },
                sender_user_id: Current.user.id
              )
            end
          end

          enqueue_chat_title(chat_session, user_message) if user_message && chat_session.messages.where(role: "user").count == 1
          enqueue_chat_turn(chat_session, user_message) if user_message

          render json: { note: note_json(note.reload), redirect_to: "/chats/#{chat_session.id}" }
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

        def find_note(job)
          job_notes(job)
            .includes(:workflow, :run, :diff_review_version, :acknowledged_by_user, :discussion_started_by_user, :last_discussed_by_user, discussion_entries: :user)
            .find(params[:id])
        end

        def job_notes(job)
          CognitiveReview::Note.where(job: job)
        end

        def discussion_message(job, note, previous_state:)
          lines = [
            "Discuss this Review Note with the operator.",
            "Job: #{job.slug}.",
            "Repository: #{job.repository.slug}.",
            "Diff review version: #{note.diff_review_version_id}.",
            "Location: #{note.path}:#{note.start_line}-#{note.end_line} (#{note.side}).",
            "State before discussion: #{previous_state}.",
            "",
            "Title:",
            note.title,
            "",
            "Explanation:",
            note.explanation
          ]
          operator_prompt = params[:message].to_s.strip
          lines.concat([ "", "Operator prompt:", operator_prompt.truncate(8_000) ]) if operator_prompt.present?
          lines.join("\n")
        end

        def discussion_chat_for(job)
          chat_session = job.discussion_chat || ChatSession.create!(user: Current.user, repository: job.repository)
          chat_session.chat_attachments.find_or_create_by!(attachable: job)
          chat_session.pin_chat_provider!
          chat_session
        end

        def note_json(note, include_detail: false)
          payload = {
            id: note.id,
            job_id: note.job_id,
            workflow_id: note.workflow_id,
            run_id: note.run_id,
            diff_review_version_id: note.diff_review_version_id,
            path: note.path,
            side: note.side,
            start_line: note.start_line,
            end_line: note.end_line,
            old_start_line: note.old_start_line,
            old_end_line: note.old_end_line,
            new_start_line: note.new_start_line,
            new_end_line: note.new_end_line,
            title: note.title,
            summary: note.summary,
            reason_codes: note.reason_codes,
            confidence: note.confidence&.to_f,
            priority: note.priority,
            state: note.state,
            acknowledged_at: note.acknowledged_at&.iso8601,
            acknowledged_by_user_id: note.acknowledged_by_user_id,
            discussion_started_at: note.discussion_started_at&.iso8601,
            discussion_started_by_user_id: note.discussion_started_by_user_id,
            last_discussed_at: note.last_discussed_at&.iso8601,
            last_discussed_by_user_id: note.last_discussed_by_user_id,
            created_at: note.created_at.iso8601,
            updated_at: note.updated_at.iso8601,
            discussion_entries: note.discussion_entries.ordered.map { |entry| discussion_entry_json(entry) }
          }
          payload.merge!(explanation: note.explanation, source_metadata: note.source_metadata) if include_detail
          payload
        end

        def discussion_entry_json(entry)
          {
            id: entry.id,
            note_id: entry.note_id,
            user_id: entry.user_id,
            body: entry.body,
            metadata: entry.metadata,
            created_at: entry.created_at.iso8601,
            updated_at: entry.updated_at.iso8601
          }
        end
      end
    end
  end
end
