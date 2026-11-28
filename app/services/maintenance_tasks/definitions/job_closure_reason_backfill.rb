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
        jobs = candidate_scope.where("id > ?", last_id).order(:id).limit(batch_size).to_a
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
        reason, references = normalized_reason(job)
        return false if reason.nil? || (reason == job.closure_reason && references.blank?)

        job.update_columns(closure_reason: reason, closure_references: references.presence, updated_at: Time.current)
        StateTransition.create!(
          subject: job, from_state: "closed", to_state: "closed", event_name: "closure_reason_backfill",
          source: "backfill", metadata: { "reason_key" => reason, "closure_reason" => reason, "references" => references, "actor_type" => "system" }.compact
        )
        true
      end

      def normalized_reason(job)
        return [ "main_grader", [] ] if job.closure_reason.blank? && job.kind == "main_grader"
        return [ "not_needed", [] ] if job.closure_reason == "no_changes"
        return [ job.landed_sha.present? ? "pr_merged" : "pr_closed", [] ] if job.closure_reason == "pr_approved"
        return cancelled_reason(job) if job.closure_reason == "cancelled"

        [ nil, [] ]
      end

      def cancelled_reason(job)
        transition = StateTransition.where(subject: job, to_state: "closed").order(created_at: :desc, id: :desc).first
        recorded = transition&.metadata.to_h.values_at("closure_reason", "reason_key").compact.find do |reason|
          Job::ClosureReason.by_reason.key?(reason.to_s) && reason.to_s != "cancelled"
        end
        return [ recorded.to_s, [] ] if recorded

        action = ChatPendingAction.where(action: "cancel_job").find do |candidate|
          candidate.payload.to_h["job_id"].to_i == job.id && candidate.payload.to_h["canonical_job_id"].present?
        end
        canonical_id = action&.payload.to_h["canonical_job_id"]
        canonical_id ? [ "duplicate", [ { type: "Job", id: canonical_id } ] ] : [ "cancelled", [] ]
      end
    end
  end
end
