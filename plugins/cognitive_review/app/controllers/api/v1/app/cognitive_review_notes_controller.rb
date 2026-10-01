module Api
  module V1
    module App
      class CognitiveReviewNotesController < BaseController
        def index
          job = find_job
          version = selected_version(job)
          notes = filtered_notes(job, version)
          render json: notes_payload(job: job, notes: notes, version: version)
        end

        def show
          job = find_job
          note = find_note(job)
          render json: notes_payload(job: job, notes: CognitiveReview::Note.where(id: note.id), version: note.diff_review_version)
        end

        def acknowledge
          job = find_job
          return unless authorize_job_mutation!(job)

          note = find_note(job)
          note.acknowledge!(user: Current.user)
          render json: notes_payload(job: job, notes: CognitiveReview::Note.where(id: note.id), version: note.diff_review_version)
        end

        def create_discussion_entry
          job = find_job
          return unless authorize_job_mutation!(job)

          note = find_note(job)
          entry = note.add_discussion_entry!(
            user: Current.user,
            body: params.require(:body),
            metadata: plain_json(params[:metadata] || {})
          )
          render json: notes_payload(
            job: job,
            notes: CognitiveReview::Note.where(id: note.id),
            version: note.diff_review_version,
            discussion_entry: entry
          ), status: :created
        rescue ActiveRecord::RecordInvalid => e
          render_error("validation_failed", e.record.errors.full_messages.to_sentence, status: :unprocessable_content)
        end

        private

        def find_job
          find_job_by_ref(policy_scope(Job).includes(:repository), params[:job_id])
        end

        def selected_version(job)
          version_id = params[:diff_review_version_id].presence || params[:version_id].presence
          return job.diff_review_versions.find(version_id) if version_id.present?

          job.diff_review_versions.latest_first.first
        end

        def filtered_notes(job, version)
          return CognitiveReview::Note.none unless version

          job_notes(job)
            .includes(:workflow, :run, :diff_review_version, :acknowledged_by_user, :discussion_started_by_user, :last_discussed_by_user, discussion_entries: :user)
            .for_diff_review_version(version.id)
            .for_path(params[:path])
            .for_state(params[:state])
            .ordered
        end

        def find_note(job)
          job_notes(job)
            .includes(:workflow, :run, :diff_review_version, :acknowledged_by_user, :discussion_started_by_user, :last_discussed_by_user, discussion_entries: :user)
            .find(params[:id])
        end

        def job_notes(job)
          CognitiveReview::Note.where(job: job)
        end

        def notes_payload(job:, notes:, version:, discussion_entry: nil)
          note_records = notes.to_a
          version_notes = CognitiveReview::Note.where(job: job, diff_review_version: version).to_a
          review_comments = CognitiveReview::Note.review_comments_for(version_notes).to_a
          {
            job_id: job.id,
            diff_review_version_id: version&.id,
            latest_version_id: job.diff_review_versions.latest_first.first&.id,
            unresolved_count: CognitiveReview::Note.open_for_pr_debt(version_notes, review_comments: review_comments).size,
            handled_count: CognitiveReview::Note.handled_for_pr_debt(version_notes, review_comments: review_comments).size,
            notes: note_records.map { |note| note_json(note) },
            by_path: by_path(note_records),
            discussion_entry: discussion_entry && discussion_entry_json(discussion_entry)
          }.compact
        end

        def by_path(notes)
          notes.each_with_object({}) do |note, paths|
            paths[note.path] ||= {}
            paths[note.path][range_key(note)] ||= []
            paths[note.path][range_key(note)] << note_json(note)
          end
        end

        def range_key(note)
          "#{note.side}:#{note.start_line}-#{note.end_line}"
        end

        def note_json(note)
          {
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
            explanation: note.explanation,
            reason_codes: note.reason_codes,
            confidence: note.confidence&.to_f,
            priority: note.priority,
            source_metadata: note.source_metadata,
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
