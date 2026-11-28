module Workflows
  # Required review gates are evidence about one exact implementation commit.
  # Dependency settlement alone is insufficient: a fanout control Step may be
  # terminal while its members are still running, and an older review may be
  # terminal after a repair changed HEAD.
  class ImmutableReviewHeadBarrier
    MUTATION_KINDS = %w[implement respond].freeze
    EXHAUSTIONS_ARTIFACT = "review_budget_exhaustions"
    EXHAUSTION_WARNING_KIND = "required_review_budget_exhausted"

    def self.reviewed_head_sha(workflow)
      workflow.steps.where(kind: MUTATION_KINDS, state: "succeeded").reorder(position: :desc, id: :desc)
        .includes(:runs).detect { |step| step.runs.last&.head_sha.present? }
        &.runs&.last&.head_sha
    end

    def self.stamp!(step, workflow)
      gate_kind = effective_review_kind(step)
      return unless gate_kind

      sha = reviewed_head_sha(workflow)
      return if sha.blank?

      step.update!(details: step.details.to_h.merge("reviewed_head_sha" => sha))
      sha
    end

    def self.satisfied_for?(step)
      workflow = step.workflow
      snapshots = required_snapshots(workflow)
      return true if snapshots.empty? || review_work_step?(step)

      sha = reviewed_head_sha(workflow)
      return true if sha.blank? # Legacy/imported workflows have no immutable identity to compare.

      snapshots.all? do |snapshot|
        evidence = terminal_evidence(workflow, snapshot.fetch("step_kind"), sha)
        (evidence&.succeeded? && approved_evidence?(workflow, evidence, snapshot)) ||
          reacted_without_head_change?(workflow, evidence, snapshot.fetch("step_kind"), sha) ||
          exhausted_for_head?(workflow, snapshot.fetch("step_kind"), sha)
      end
    end

    # A review budget is runaway protection, not a reason to discard a
    # successful final repair. Preserve the immutable-HEAD boundary by
    # recording an explicit exception for this gate and exact repaired HEAD;
    # stale evidence remains superseded and can never satisfy the barrier.
    def self.record_budget_exhaustion!(workflow, repair_step, review_kind)
      sha = reviewed_head_sha(workflow)
      return if sha.blank?

      entry = {
        "review_kind" => review_kind,
        "head_sha" => sha,
        "repair_step_id" => repair_step.id,
        "repair_run_id" => repair_step.runs.reorder(:id).last&.id,
        "recorded_at" => Time.current.iso8601
      }
      exhaustions = Array(workflow.artifact(EXHAUSTIONS_ARTIFACT))
      unless exhaustions.any? { |existing| exhaustion_matches?(existing, review_kind, sha) }
        workflow.set_artifact!(EXHAUSTIONS_ARTIFACT, exhaustions + [ entry ])
      end

      warning = workflow.workflow_warnings.where(kind: EXHAUSTION_WARNING_KIND, state: "pending").detect do |candidate|
        exhaustion_matches?(candidate.evidence.to_h, review_kind, sha)
      end
      warning || WorkflowWarnings.record!(
        workflow: workflow,
        step: repair_step,
        kind: EXHAUSTION_WARNING_KIND,
        severity: "high",
        title: "#{review_kind.humanize} budget exhausted; final repaired HEAD was not re-reviewed",
        evidence: entry
      )
    end

    def self.invalidate_stale_evidence!(workflow)
      sha = reviewed_head_sha(workflow)
      return if sha.blank?

      review_steps(workflow).reorder(nil).find_each do |candidate|
        next unless effective_review_kind(candidate)
        reviewed_sha = candidate.details.to_h["reviewed_head_sha"]
        next if reviewed_sha.blank? || reviewed_sha == sha

        # A gate that has not started has produced no evidence; it will review
        # whatever HEAD is current when it runs. Point it at the new HEAD.
        # Cancelling it instead also cancelled the chain behind it (format,
        # graders, PR) and left the workflow with nothing to run.
        if not_started?(candidate)
          candidate.update!(details: candidate.details.to_h.merge("reviewed_head_sha" => sha))
          next
        end

        details = candidate.details.to_h.merge(
          "review_evidence_superseded" => true,
          "superseded_by_head_sha" => sha
        )
        Step.suppress_cancel_cascade do
          candidate.cancel if candidate.may_cancel?
          candidate.details = details
          candidate.cancellation_reason ||= "implementation_head_changed"
          candidate.save!
          candidate.runs.active.each { |run| cancel_run_without_cascade!(run) }
        end
      end
    end

    def self.not_started?(step)
      step.queued? && step.runs.where.not(started_at: nil).none? && step.runs.where.not(state: "queued").none?
    end

    def self.cancel_run_without_cascade!(run)
      return unless run&.may_cancel?

      # Run's ordinary cancelled callback models an operator stop and cancels
      # the owning Step and Workflow. Barrier invalidation is expected graph
      # maintenance, so persist the terminal Run without that callback.
      now = Time.current
      run.cancel_columns_if_active!(finished_at: now, updated_at: now)
    end

    # A repair belongs to one review loop, but invalidates the evidence from
    # every required loop. Recreate any sibling loop whose old generation was
    # cancelled so the barrier can converge instead of waiting forever for
    # evidence that can no longer be produced.
    def self.refresh_required_reviews!(workflow, repair_step)
      sha = reviewed_head_sha(workflow)
      return [] if sha.blank?

      created = []
      # Invalidation cancels Runs and rewrites Steps in mixed order, so the
      # whole subtree is locked first, top down (NY40); then the Workflow is
      # reloaded as with_lock would.
      Workflow.transaction do
        Lineage.lock_subtree!(workflow)
        workflow.reload(lock: true)
        Step.transaction do
          invalidate_stale_evidence!(workflow)
          repair_step.reload(lock: true)
          continuation = repair_step.next_step
          snapshots = required_snapshots(workflow)

          snapshots.each do |snapshot|
            kind = snapshot.fetch("step_kind")
            next if exhausted_for_head?(workflow, kind, sha)

            evidence = terminal_evidence(workflow, kind, sha)
            next if reacted_without_head_change?(workflow, evidence, kind, sha)

            fresh = review_steps(workflow).where(state: Step::ACTIVE_STATES).reorder(position: :desc, id: :desc).detect do |candidate|
              effective_review_kind(candidate) == kind &&
                candidate.details.to_h["reviewed_head_sha"].in?([ nil, sha ])
            end
            if fresh
              fresh.update!(details: fresh.details.to_h.merge("reviewed_head_sha" => sha, "required" => true))
              next
            end

            previous = review_steps(workflow).reorder(position: :desc, id: :desc).detect do |candidate|
              effective_review_kind(candidate) == kind && candidate.loop_id.present?
            end
            next unless previous

            workflow.steps.where("position >= ?", repair_step.position + 1).update_all("position = position + 1")
            step = Step.create!(
              workflow: workflow,
              kind: kind,
              position: repair_step.position + 1,
              iteration: previous.iteration + 1,
              loop_id: previous.loop_id,
              next_step: continuation,
              depends_on_ids: [ repair_step.id ],
              placement_policy: Step::Kind.fetch(kind).placement_policy_for(workflow.job.repository),
              details: {
                "reviewed_head_sha" => sha,
                "required" => true,
                "review_barrier_rematerialized" => true
              }
            )
            repair_step.update!(next_step: step)
            StepDispatcher.wire_inserted_step_dependencies!(
              previous: repair_step, new_steps: [ step ], continuation: continuation
            )
            continuation = step
            created << step
          end
        end
      end
      created
    end

    # Only reviewer steps and review-panel collectors carry an effective
    # review kind. Every barrier lookup used to load all of a workflow's
    # steps -- full rows, JSON details included -- and filter in Ruby, once per
    # required review, on every readiness check of every queued step. On a
    # workflow with hundreds of steps and large grader fan-out rows that meant
    # gigabytes per dispatcher or reconciler pass, and a reconciler pass that
    # never finished. Filter in SQL instead.
    def self.review_steps(workflow)
      workflow.steps.where(kind: Step::Kind.review_gate_kinds + [ "review_panel_collect" ])
    end

    def self.effective_review_kind(step)
      return if step.nil?

      step.details.to_h["panel_review_kind"].presence ||
        (step.kind if Step::Kind.review_gate_for(step.kind))
    end

    def self.review_work_step?(step)
      effective_review_kind(step).present? ||
        (MUTATION_KINDS.include?(step.kind) && step.loop_id.present?)
    end

    def self.required_snapshots(workflow)
      Array(workflow.artifact("review_gate_contributions")).select do |snapshot|
        next false unless snapshot.fetch("required", true) == true

        latest_explicit = review_steps(workflow).reorder(position: :desc, id: :desc).detect do |step|
          effective_review_kind(step) == snapshot["step_kind"] && step.details.to_h.key?("required")
        end
        latest_explicit.nil? || latest_explicit.details.to_h["required"] != false
      end
    end

    def self.terminal_evidence(workflow, kind, sha)
      review_steps(workflow).reorder(position: :desc, id: :desc).detect do |candidate|
        effective_review_kind(candidate) == kind &&
          !candidate.details.to_h["panel_fanout"] &&
          !candidate.details.to_h["panel_member"] &&
          candidate.details.to_h["reviewed_head_sha"] == sha &&
          candidate.details.to_h["review_evidence_superseded"] != true &&
          candidate.terminal?
      end
    end

    def self.approved_evidence?(workflow, step, snapshot)
      artifact_key = snapshot.fetch("verdict_artifact")
      entry = Array(workflow.artifact(artifact_key)).reverse.find do |entry|
        entry["reviewed_head_sha"] == step.details.to_h["reviewed_head_sha"] &&
          (!step.details.to_h["panel_id"] || entry["panel_id"] == step.details.to_h["panel_id"]) &&
          (step.kind != "review_panel_collect" || entry["aggregate"] == true)
      end
      verdict = entry&.fetch("effective_verdict", nil) || entry&.fetch("verdict", nil)
      Array(snapshot.fetch("exit_verdicts", %w[approved skipped])).include?(verdict)
    end

    def self.exhausted_for_head?(workflow, review_kind, sha)
      Array(workflow.artifact(EXHAUSTIONS_ARTIFACT)).any? do |entry|
        exhaustion_matches?(entry, review_kind, sha)
      end
    end

    def self.exhaustion_matches?(entry, review_kind, sha)
      entry.to_h["review_kind"] == review_kind && entry.to_h["head_sha"] == sha
    end

    # A final repair that leaves HEAD unchanged has reacted to evidence that is
    # still current. It needs neither a fresh review round nor the warning used
    # when changed HEAD has consumed the remaining review budget.
    def self.reacted_without_head_change?(workflow, evidence, review_kind, sha)
      return false unless evidence&.succeeded? && evidence.loop_id.present?

      workflow.steps.where(kind: MUTATION_KINDS, state: "succeeded").reorder(position: :desc, id: :desc).any? do |repair|
        next false unless repair.loop_id == evidence.loop_id && repair.position > evidence.position
        next false unless repair.runs.reorder(:id).last&.head_sha == sha

        effective_review_kind(repair.next_step) != review_kind
      end
    end

    private_class_method :required_snapshots, :terminal_evidence, :approved_evidence?, :exhaustion_matches?,
      :reacted_without_head_change?
  end
end
