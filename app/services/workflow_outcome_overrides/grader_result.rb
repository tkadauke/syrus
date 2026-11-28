require "digest"

module WorkflowOutcomeOverrides
  class GraderResult
    def self.apply!(workflow:, grader_step:, candidate_head_sha:, candidate_tree_sha:, candidate_base_sha:, grader_plan_digest:, required_grader_plan:)
      new(workflow:, grader_step:, candidate_head_sha:, candidate_tree_sha:, candidate_base_sha:, grader_plan_digest:, required_grader_plan:).apply!
    end

    def initialize(workflow:, grader_step:, candidate_head_sha:, candidate_tree_sha:, candidate_base_sha:, grader_plan_digest:, required_grader_plan:)
      @workflow = workflow
      @grader_step = grader_step
      @candidate_head_sha = candidate_head_sha.to_s
      @candidate_tree_sha = candidate_tree_sha.to_s
      @candidate_base_sha = candidate_base_sha.to_s
      @grader_plan_digest = grader_plan_digest.to_s
      @required_grader_plan = required_grader_plan
    end

    def apply!
      return false unless failure[:technically_overridable]

      invalidate_stale_overrides!
      # An override this exact grader Step already consumed stays accepted when
      # the collector reruns against the same evidence (another grader's
      # override resuming the gate, or a retried collect Run). Every column of
      # the fingerprint is matched, so a consumed match can only be this Step's
      # own decision about this exact HEAD, plan, and evidence.
      override = WorkflowOutcomeOverride.where(
        job_id: workflow.job_id, workflow_id: workflow.id, step_id: grader_step.id,
        gate_kind: gate_kind, gate_identity: gate_identity,
        candidate_head_sha: candidate_head_sha, candidate_tree_sha: candidate_tree_sha.presence,
        candidate_base_sha: candidate_base_sha.presence, plan_version: plan_version,
        evidence_digest: evidence_digest, invalidation_cause: nil
      ).order(Arel.sql("consumed_at IS NULL"), :id).first
      return false unless override

      override.consume!(override.fingerprint)
      grader_step.update!(details: details.merge(
        "outcome_override" => {
          "id" => override.id, "effective_outcome" => "accepted_failure",
          "original_outcome" => GraderOutcome::TEST_FAILED,
          "consumed_at" => override.consumed_at.iso8601
        }
      ))
      true
    end

    def failure
      {
        outcome: "failed", technically_overridable: details["technically_overridable"] == true,
        structural: grader_outcome.outcome != GraderOutcome::TEST_FAILED,
        gate_identity: gate_identity, evidence_digest: evidence_digest,
        candidate_head_sha: candidate_head_sha, candidate_tree_sha: candidate_tree_sha.presence,
        candidate_base_sha: candidate_base_sha.presence, plan_version: plan_version
      }
    end

    def gate_kind
      LandingGraderPlan::LANDING_TRIGGER_KINDS.include?(workflow.trigger_kind) ? "landing_grader" : "implementation_grader"
    end

    def gate_identity = details["target_label"].presence || details["name"].to_s

    def evidence_digest
      @evidence_digest ||= digest(
        "grader_key" => gate_identity, "outcome" => grader_outcome.to_h,
        "command" => details["command"], "exit_code" => details["exit_code"],
        "output" => details["output"], "log_path" => details["log_path"],
        "log_bytes" => details["log_bytes"], "junit_output" => details["junit_output"],
        "json_output" => details["json_output"]
      )
    end

    def plan_version
      @plan_version ||= digest(
        "grader_plan_digest" => grader_plan_digest, "grader_key" => gate_identity,
        "command_fingerprint" => details.dig("target_fingerprints", "command_fingerprint"),
        "input_fingerprint" => details.dig("target_fingerprints", "input_fingerprint"),
        "environment_fingerprint" => details.dig("target_fingerprints", "environment_fingerprint"),
        "required_grader_plan" => required_grader_plan
      )
    end

    private

    attr_reader :workflow, :grader_step, :candidate_head_sha, :candidate_tree_sha,
      :candidate_base_sha, :grader_plan_digest, :required_grader_plan

    def details = grader_step.details.to_h
    def grader_outcome = @grader_outcome ||= GraderOutcome.for_step(grader_step)
    def digest(value) = Digest::SHA256.hexdigest(JSON.generate(deep_sort(value)))

    def invalidate_stale_overrides!
      WorkflowOutcomeOverride.where(
        job_id: workflow.job_id, gate_kind: gate_kind, gate_identity: gate_identity,
        consumed_at: nil, invalidation_cause: nil
      ).find_each do |override|
        next if override.fingerprint.digest == current_fingerprint.digest

        override.invalidate!(invalidation_cause_for(override))
      end
    end

    def current_fingerprint
      WorkflowOutcomeOverrides::Fingerprint.new(
        job_id: workflow.job_id, workflow_id: workflow.id, step_id: grader_step.id,
        gate_kind: gate_kind, gate_identity: gate_identity,
        candidate_head_sha: candidate_head_sha, candidate_tree_sha: candidate_tree_sha.presence,
        candidate_base_sha: candidate_base_sha.presence, plan_version: plan_version,
        prompt_version: nil, evidence_digest: evidence_digest
      )
    end

    def invalidation_cause_for(override)
      return "candidate_changed" if override.candidate_head_sha != candidate_head_sha || override.candidate_tree_sha.to_s != candidate_tree_sha
      return "base_changed" if override.candidate_base_sha.to_s != candidate_base_sha
      return "grader_plan_changed" if override.plan_version != plan_version
      return "evidence_changed" if override.evidence_digest != evidence_digest

      "grader_instance_changed"
    end

    def deep_sort(value)
      case value
      when Hash
        hash = value.stringify_keys
        hash.keys.sort.to_h { |key| [ key, deep_sort(hash[key]) ] }
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end
  end
end
