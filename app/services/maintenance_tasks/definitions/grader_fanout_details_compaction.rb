module MaintenanceTasks
  module Definitions
    # Grader fan-out Steps used to copy every target's full fingerprints into
    # their details. On a large repository that made a single Step row larger
    # than MySQL's sort buffer, and any query sorting full step rows -- the job
    # page, bulk job actions, restarting a grade loop -- then failed with
    # "Out of sort memory". New fan-outs write compact entries; this compacts
    # the rows written before that.
    class GraderFanoutDetailsCompaction < Base
      FANOUT_KINDS = %w[grader_fanout preflight_grader_fanout].freeze
      ENTRY_KEYS = [
        Steps::GraderFanout::TARGET_SELECTIONS_ARTIFACT_KEY,
        Steps::GraderFanout::TARGET_HEALTH_SKIPS_ARTIFACT_KEY,
        Steps::GraderFanout::TARGET_HEALTH_FORCED_ARTIFACT_KEY
      ].freeze
      OMITTED_ENTRY_KEYS = Steps::GraderFanout::STEP_DETAIL_OMITTED_ENTRY_KEYS

      key "grader_fanout_details_compaction"
      title "Compact grader fan-out step details"
      summary "Drops per-target fingerprints from old grader fan-out step details; the workflow artifacts keep them."
      category "repair"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "grader_fanout_details_compaction"
      batch_size 100
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/grader_fanout_details_compaction.md")

      step "compact", "Compact fan-out steps", "Rewrites each oversized fan-out Step's details without the per-target fingerprints."

      def estimate_total_units
        candidates.count
      end

      def pending_reason
        "#{estimate_total_units} grader fan-out step(s) still carry per-target fingerprints in their details."
      end

      def perform_batch(task)
        task.current_step_key = "compact"
        task.current_step_title = "Compact fan-out steps"

        # Ids only, unsorted: sorting full step rows is the query that fails.
        ids = candidates.limit(batch_size).pluck(:id)
        ids.each { |id| compact!(::Step.find(id)) }

        Result.new(
          done: ids.size < batch_size,
          processed: ids.size,
          failed: 0,
          message: "Compacted #{ids.size} grader fan-out step(s).",
          level: "progress"
        )
      end

      def compact!(step)
        details = step.details.to_h
        ENTRY_KEYS.each do |entry_key|
          next unless details[entry_key].is_a?(Array)

          details[entry_key] = details[entry_key].map do |entry|
            entry.is_a?(Hash) ? entry.stringify_keys.except(*OMITTED_ENTRY_KEYS) : entry
          end
        end
        step.update_columns(details: details)
      end

      private

      def candidates
        ::Step.unscoped.where(kind: FANOUT_KINDS).where("details LIKE ?", "%target_fingerprints%")
      end
    end
  end
end
