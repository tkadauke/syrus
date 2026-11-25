module WorkflowOutcomeOverrides
  # Reconstructs override candidates from the same persisted evidence consumed
  # by the gate integrations. Callers never get to submit their own evidence.
  class CandidateResolver
    class NotFound < KeyError; end

    def self.for_job(job) = new(job).candidates

    def initialize(job)
      @job = job
    end

    def candidates
      job.workflows.includes(:job, :workflow_artifact_values, steps: :runs).order(created_at: :desc).flat_map do |workflow|
        grader_candidates(workflow) + review_candidates(workflow)
      end
    end

    def find!(fingerprint_digest)
      candidates.find { |candidate| candidate.fingerprint.digest == fingerprint_digest.to_s } ||
        raise(NotFound, "override candidate is stale or unavailable")
    end

    private

    attr_reader :job

    def grader_candidates(workflow)
      graders = workflow.steps.select { |step| step.kind.in?(%w[grader preflight_grader]) }
      required_plan = graders.select { |step| step.details.to_h["required"] }.map do |step|
        details = step.details.to_h
        { "grader_key" => details["target_label"].presence || details["name"],
          "command_fingerprint" => details.dig("target_fingerprints", "command_fingerprint"), "required" => true }
      end.sort_by { |entry| entry["grader_key"].to_s }

      graders.filter_map do |step|
        next unless step.failed? && step.details.to_h["required"]
        next if step.details.to_h.dig("outcome_override", "effective_outcome") == "accepted_failure"

        result = GraderResult.new(
          workflow:, grader_step: step,
          candidate_head_sha: workflow.artifact(GraderConclusionCache::ARTIFACT_HEAD_SHA_KEY),
          candidate_tree_sha: step.details.to_h.dig("source_snapshot", "tree_sha"),
          candidate_base_sha: workflow.artifact(GraderConclusionCache::ARTIFACT_BASE_SHA_KEY),
          grader_plan_digest: workflow.artifact(GraderConclusionCache::ARTIFACT_FINGERPRINT_KEY),
          required_grader_plan: required_plan
        )
        failure = result.failure.merge(gate_kind: result.gate_kind)
        next unless GateRegistry.default.fetch(result.gate_kind).overridable_failure?(failure)

        Candidate.new(workflow:, step:, gate_failure: failure,
          label: step.details.to_h["display_name"].presence || result.gate_identity,
          consequence: "This failed grader will remain recorded as failed, overridden, and the workflow may advance.")
      end
    end

    def review_candidates(workflow)
      workflow.steps.filter_map do |review_step|
        details = review_step.details.to_h
        review_kind = details["panel_review_kind"].presence || review_step.kind
        next unless Step::Kind.review_gate_for(review_kind)
        next if details["panel_member"] && review_step.kind != "review_panel_collect"

        artifact_key = Step::Kind.fetch(review_kind).review_gate.fetch(:artifact_key)
        votes = Array(workflow.artifact(artifact_key)).select do |vote|
          vote["iteration"].to_i == review_step.iteration && !vote["aggregate"] &&
            (review_step.kind != "review_panel_collect" || vote["panel_id"] == details["panel_id"])
        end
        votes.filter_map do |vote|
          next if vote["effective_verdict"] == "approved"
          next unless vote["verdict"].in?(%w[needs_work skipped]) && details["reviewed_head_sha"].present?

          gate_kind = vote["verdict"] == "skipped" ? "reviewer_infrastructure" : "review"
          identity = ReviewVerdict.gate_identity(review_kind:, panel_id: details["panel_id"], vote:)
          failure = {
            outcome: "failed", technically_overridable: true, structural: false,
            gate_kind:, gate_identity: identity, evidence_digest: ReviewVerdict.evidence_digest(vote),
            candidate_head_sha: details["reviewed_head_sha"], candidate_tree_sha: nil,
            candidate_base_sha: nil, plan_version: nil,
            prompt_version: vote["prompt_version"].presence || review_kind
          }
          Candidate.new(workflow:, step: review_step, gate_failure: failure,
            label: identity,
            consequence: "This member's negative evidence remains visible, but it will count as approved for this exact review revision.")
        end
      end.flatten
    end
  end
end
