module MaintenanceTasks
  module Definitions
    class JobClosureReasonBackfill < Base
      key "job_closure_reason_backfill"
      title "Backfill Job closure reasons"
      summary "Normalizes legacy Job closure reasons and records backfill provenance."
      category "backfill"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "job_closure_reason_backfill"
      batch_size 250
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/job_closure_reason_backfill.md")

      step "jobs", "Normalize closed Jobs", "Walks primary-key windows and updates only deterministically mappable closures."

      def estimate_total_units = candidate_scope.count

      def perform_batch(task)
        task.current_step_key = "jobs"
        task.current_step_title = "Normalize closed Jobs"
        last_id = task.checkpoint.to_h["last_id"].to_i
        jobs = candidate_scope.where("id > ?", last_id).order(:id).limit(batch_size).includes(:pr_links).to_a
        load_evidence(jobs)
        changed = jobs.count { |job| normalize!(job) }
        task.checkpoint = task.checkpoint.to_h.merge("last_id" => jobs.last&.id || last_id)

        Result.new(
          done: jobs.length < batch_size,
          processed: jobs.length,
          failed: 0,
          message: "Checked #{jobs.length} closed Job(s); normalized #{changed}."
        )
      end

      private

      def candidate_scope
        Job.closed_threads.where(closure_reason: [ nil, "", "pr_approved", "no_changes", "cancelled" ])
      end

      def normalize!(job)
        reason, references, note = normalized_reason(job)
        return false if reason.nil? || (reason == job.closure_reason && references.blank? && note.blank?)

        job.update_columns(
          closure_reason: reason, closure_references: references.presence,
          closure_note: note.to_s.presence, updated_at: Time.current
        )
        prior = transition_for(job)
        provenance = if prior
          prior.metadata.to_h.slice("actor_type", "actor_id", "actor_record_type", "actor_record_id", "chat_session_id")
            .merge("via" => prior.metadata.to_h["via"].presence || prior.source)
        else
          { "actor_type" => "system", "via" => "backfill" }
        end
        StateTransition.create!(
          subject: job, from_state: "closed", to_state: "closed", event_name: "closure_reason_backfill",
          source: "backfill", user_id: prior&.user_id,
          metadata: provenance.merge("reason_key" => reason, "closure_reason" => reason, "references" => references).compact
        )
        true
      end

      def normalized_reason(job)
        return [ "main_grader", [], nil ] if job.closure_reason.blank? && job.kind == "main_grader"
        return [ "not_needed", [], nil ] if job.closure_reason == "no_changes"
        return [ pr_merged?(job) ? "pr_merged" : "pr_closed", [], nil ] if job.closure_reason == "pr_approved"
        return cancelled_reason(job) if job.closure_reason == "cancelled"

        [ nil, [], nil ]
      end

      def cancelled_reason(job)
        transition = transition_for(job)
        transition_metadata = transition&.metadata.to_h
        recorded = transition_metadata.to_h.values_at("closure_reason", "reason_key").compact.find do |reason|
          Job::ClosureReason.by_reason.key?(reason.to_s) && reason.to_s != "cancelled"
        end
        if recorded
          references = Array(transition_metadata["references"])
          canonical_id = transition_metadata["canonical_job_id"]
          references = [ { type: "Job", id: canonical_id } ] if references.empty? && canonical_id.present?
          note = transition_metadata["note"]
          definition = Job::ClosureReason.fetch(recorded)
          complete = (!definition.requires_reference || references.any?) && (!definition.requires_note || note.present?)
          return [ recorded.to_s, references, note ] if complete
        end

        action = action_for(job)
        canonical_id = action&.payload.to_h["canonical_job_id"]
        return [ "duplicate", [ { type: "Job", id: canonical_id } ], action.payload.to_h["reason"] ] if canonical_id

        payload_reason = [ action&.payload.to_h&.[]("closure_reason"), action&.payload.to_h&.[]("reason"), action&.reason ].compact.find do |reason|
          Job::ClosureReason.by_reason.key?(reason.to_s) && reason.to_s != "cancelled"
        end
        if payload_reason
          definition = Job::ClosureReason.fetch(payload_reason)
          note = action.payload.to_h["note"]
          return [ payload_reason.to_s, [], note ] unless definition.requires_note && note.blank?
        end
        [ "cancelled", [], nil ]
      end

      def load_evidence(jobs)
        ids = jobs.map(&:id)
        @transitions_by_job_id = StateTransition.where(subject_type: "Job", subject_id: ids, to_state: "closed")
          .order(created_at: :desc, id: :desc).group_by(&:subject_id).transform_values(&:first)
        @actions_by_job_id = ChatPendingAction.where(action: "cancel_job")
          .where("JSON_EXTRACT(payload, '$.job_id') IN (?)", ids)
          .order(created_at: :desc, id: :desc).group_by { |action| action.payload.to_h["job_id"].to_i }
          .transform_values(&:first)
      end

      def transition_for(job) = @transitions_by_job_id.fetch(job.id, nil)
      def action_for(job) = @actions_by_job_id.fetch(job.id, nil)

      def pr_merged?(job)
        job.landed_sha.present? || job.pr_links.any? { |link| link.metadata.to_h["pr_state"] == "merged" }
      end
    end
  end
end
