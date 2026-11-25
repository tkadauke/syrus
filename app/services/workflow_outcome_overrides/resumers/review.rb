module WorkflowOutcomeOverrides
  module Resumers
    class Review
      SUPERSESSION_REASON = "review_outcome_override".freeze

      def self.call(override) = new(override).call

      def initialize(override)
        @override = override
      end

      def call
        return retry_failed_collector if workflow.failed? && step.failed?

        reconcile_active_loop!
      end

      private

      attr_reader :override

      def workflow = override.workflow
      def step = override.step

      def retry_failed_collector
        result = RetryFailedStepEnqueuer.call(
          workflow:, failed_step: step, restart_grade_loop: false
        )
        raise Resumer::ResumeFailed, result.error unless result.success?

        result
      end

      def reconcile_active_loop!
        review_kind = step.details.to_h["panel_review_kind"].presence || step.kind
        artifact_key = Step::Kind.fetch(review_kind).review_gate.fetch(:artifact_key)
        entries = Array(workflow.artifact(artifact_key))
        vote_index = entries.index do |entry|
          !entry["aggregate"] && entry["iteration"].to_i == step.iteration &&
            ReviewVerdict.evidence_digest(entry) == override.evidence_digest
        end
        raise Resumer::ResumeFailed, "review evidence is no longer available" unless vote_index

        ensure_loop_can_be_superseded!
        entries[vote_index] = apply_override(entries.fetch(vote_index), review_kind)
        aggregate_index = matching_aggregate_index(entries)
        entries[aggregate_index] = recompute_aggregate(entries, aggregate_index) if aggregate_index
        workflow.set_artifact!(artifact_key, entries)

        effective_verdict = aggregate_index ? entries.fetch(aggregate_index)["verdict"] : entries.fetch(vote_index)["effective_verdict"]
        supersede_repair_continuation! if effective_verdict == "approved"
        override
      end

      def apply_override(vote, review_kind)
        ReviewVerdict.apply!(
          workflow:, collector_step: step, review_kind:,
          panel_id: vote["panel_id"], reviewed_head_sha: step.details.to_h["reviewed_head_sha"], vote:
        )
      end

      def matching_aggregate_index(entries)
        entries.rindex do |entry|
          entry["aggregate"] && entry["iteration"].to_i == step.iteration &&
            entry["panel_id"].to_s == step.details.to_h["panel_id"].to_s
        end
      end

      def recompute_aggregate(entries, aggregate_index)
        details = step.details.to_h
        votes = entries.select do |entry|
          !entry["aggregate"] && entry["iteration"].to_i == step.iteration &&
            entry["panel_id"].to_s == details["panel_id"].to_s
        end
        result = ProviderRouting::PanelConsensus.call(
          member_verdicts: votes.map { |vote| vote.merge("verdict" => vote["effective_verdict"] || vote["verdict"]) },
          consensus: details.fetch("consensus"), min_members: details.fetch("min_members")
        )
        entries.fetch(aggregate_index).merge(
          "verdict" => result.verdict,
          "vote_breakdown" => result.breakdown,
          "votes" => votes.map { |vote| vote.slice("provider", "model", "verdict", "effective_verdict", "original_verdict", "outcome_override_id") },
          "non_blocking_findings" => result.verdict == "approved" ?
            votes.select { |vote| vote["verdict"] == "needs_work" }.map { |vote| vote.slice("provider", "model", "critique") } : []
        )
      end

      def loop_descendants
        @loop_descendants ||= begin
          cursor = step.reload.next_step
          descendants = []
          while cursor&.loop_id == step.loop_id
            descendants << cursor
            cursor = cursor.next_step
          end
          @continuation = cursor
          descendants
        end
      end

      def ensure_loop_can_be_superseded!
        started = loop_descendants.find { |candidate| candidate.running? || candidate.succeeded? || candidate.failed? }
        return unless started

        raise Resumer::ResumeFailed, "review repair already started at Step ##{started.id}; exact reviewed revision can no longer advance"
      end

      def supersede_repair_continuation!
        descendants = loop_descendants
        continuation = @continuation
        return if descendants.empty?

        workflow.with_lock do
          Step.transaction do
            descendants.each do |candidate|
              candidate.runs.active.find_each(&:cancel_without_step_cascade!)
              candidate.update_columns(
                state: "skipped", finished_at: Time.current,
                details: candidate.details.to_h.merge("skipped" => true, "skip_reason" => SUPERSESSION_REASON),
                updated_at: Time.current
              ) if candidate.queued?
            end
            step.update!(next_step_id: continuation&.id)
            rewire_continuation_dependencies!(continuation, descendants)
          end
        end
        StepDispatcher.create_run_and_enqueue(continuation, workflow) if continuation&.queued? && continuation.runs.none?
      end

      def rewire_continuation_dependencies!(continuation, descendants)
        return unless continuation

        ids = Array(continuation.depends_on_ids).map(&:to_i)
        replaced = ids - descendants.map(&:id)
        replaced << step.id if replaced.size != ids.size
        continuation.update!(depends_on_ids: replaced.uniq)
      end
    end
  end
end
