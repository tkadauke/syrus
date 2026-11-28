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
        continuation = nil
        WorkflowOutcomeOverride.transaction do
          # Run claiming takes the same ancestry first. Holding it while the
          # loop Steps and Runs are re-read prevents a queued repair from
          # starting between validation and supersession.
          Lineage.lock!(step)
          # Only a live Workflow's loop is rewired (F146): on a blocked or
          # cancelled one, rewriting its repair to skipped past AASM left a
          # blocked attempt that an answer could no longer resume, and the
          # continuation's Run was queued under a terminal Workflow.
          if workflow.reload.terminal?
            raise Resumer::ResumeFailed, "Workflow ##{workflow.id} is #{workflow.state}; its review loop can no longer be resumed"
          end
          source, descendants, loop_continuation, active_runs = locked_loop_segment
          ensure_loop_can_be_superseded!(descendants, active_runs)

          review_kind = source.details.to_h["panel_review_kind"].presence || source.kind
          artifact_key = Step::Kind.fetch(review_kind).review_gate.fetch(:artifact_key)
          workflow.workflow_artifact_values.reset
          entries = Array(workflow.artifact(artifact_key))
          vote_index = entries.index do |entry|
            !entry["aggregate"] && entry["iteration"].to_i == source.iteration &&
              ReviewVerdict.evidence_digest(entry) == override.evidence_digest
          end
          raise Resumer::ResumeFailed, "review evidence is no longer available" unless vote_index

          entries[vote_index] = apply_override(entries.fetch(vote_index), review_kind, source)
          aggregate_index = matching_aggregate_index(entries, source)
          entries[aggregate_index] = recompute_aggregate(entries, aggregate_index, source) if aggregate_index
          effective_verdict = aggregate_index ? entries.fetch(aggregate_index)["verdict"] : entries.fetch(vote_index)["effective_verdict"]

          if effective_verdict == "approved"
            supersede_repair_continuation!(source, descendants, loop_continuation, active_runs)
            continuation = loop_continuation
          end
          workflow.set_artifact!(artifact_key, entries)
        end
        StepDispatcher.create_run_and_enqueue(continuation, workflow) if continuation&.queued? && continuation.runs.none?
        override
      end

      def apply_override(vote, review_kind, source)
        ReviewVerdict.apply!(
          workflow:, collector_step: source, review_kind:,
          panel_id: vote["panel_id"], reviewed_head_sha: source.details.to_h["reviewed_head_sha"], vote:
        )
      end

      def matching_aggregate_index(entries, source)
        entries.rindex do |entry|
          entry["aggregate"] && entry["iteration"].to_i == source.iteration &&
            entry["panel_id"].to_s == source.details.to_h["panel_id"].to_s
        end
      end

      def recompute_aggregate(entries, aggregate_index, source)
        details = source.details.to_h
        votes = entries.select do |entry|
          !entry["aggregate"] && entry["iteration"].to_i == source.iteration &&
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

      def locked_loop_segment
        steps_by_id = workflow.steps.lock.to_a.index_by(&:id)
        source = steps_by_id.fetch(step.id)
        cursor = steps_by_id[source.next_step_id]
        descendants = []
        visited = Set.new
        while cursor&.loop_id == source.loop_id
          raise Resumer::ResumeFailed, "review repair loop contains a cycle" unless visited.add?(cursor.id)

          descendants << cursor
          cursor = steps_by_id[cursor.next_step_id]
        end
        active_runs = descendants.empty? ? [] : Run.active.where(step_id: descendants.map(&:id)).lock.to_a
        [ source, descendants, cursor, active_runs ]
      end

      def ensure_loop_can_be_superseded!(descendants, active_runs)
        started = descendants.find { |candidate| candidate.running? || candidate.succeeded? || candidate.failed? }
        started ||= descendants.find { |candidate| active_runs.any? { |run| run.step_id == candidate.id && run.running? } }
        return unless started

        raise Resumer::ResumeFailed, "review repair already started at Step ##{started.id}; exact reviewed revision can no longer advance"
      end

      def supersede_repair_continuation!(source, descendants, continuation, active_runs)
        return if descendants.empty?

        descendants.each do |candidate|
          active_runs.select { |run| run.step_id == candidate.id }.each(&:cancel_without_step_cascade!)
          candidate.update_columns(
            state: "skipped", finished_at: Time.current,
            details: candidate.details.to_h.merge("skipped" => true, "skip_reason" => SUPERSESSION_REASON),
            updated_at: Time.current
          )
        end
        source.update!(next_step_id: continuation&.id)
        rewire_continuation_dependencies!(source, continuation, descendants)
      end

      def rewire_continuation_dependencies!(source, continuation, descendants)
        return unless continuation

        ids = Array(continuation.depends_on_ids).map(&:to_i)
        replaced = ids - descendants.map(&:id)
        replaced << source.id if replaced.size != ids.size
        continuation.update!(depends_on_ids: replaced.uniq)
      end
    end
  end
end
