require "digest"

module WorkflowOutcomeOverrides
  class ReviewVerdict
    def self.apply!(workflow:, collector_step:, review_kind:, panel_id:, reviewed_head_sha:, vote:)
      new(
        workflow:, collector_step:, review_kind:, panel_id:,
        reviewed_head_sha:, vote: vote.to_h.stringify_keys
      ).apply!
    end

    def initialize(workflow:, collector_step:, review_kind:, panel_id:, reviewed_head_sha:, vote:)
      @workflow = workflow
      @collector_step = collector_step
      @review_kind = review_kind.to_s
      @panel_id = panel_id.to_s
      @reviewed_head_sha = reviewed_head_sha.to_s
      @vote = vote
    end

    def apply!
      return vote unless vote["verdict"].in?(%w[needs_work skipped])
      return vote if reviewed_head_sha.blank?

      # A consumed override still applies to the identical vote: a panel
      # collector rerun (another member's override resuming the gate, or a
      # retried collect Run) re-reads the member votes, which never record the
      # override themselves. The evidence digest covers the whole vote, so a
      # consumed match is the same decision about this exact reviewed HEAD.
      override = WorkflowOutcomeOverride.where(
        job_id: workflow.job_id,
        workflow_id: workflow.id,
        gate_kind: gate_kind,
        gate_identity: gate_identity,
        candidate_head_sha: reviewed_head_sha,
        evidence_digest: evidence_digest,
        invalidation_cause: nil
      ).order(Arel.sql("consumed_at IS NULL"), :id).first
      return vote unless override

      override.consume!(override.fingerprint)
      vote.merge(
        "effective_verdict" => "approved",
        "outcome_override_id" => override.id,
        "original_verdict" => vote["verdict"]
      )
    end

    def self.gate_identity(review_kind:, panel_id:, vote:)
      vote = vote.to_h.stringify_keys
      member = [ vote["provider"], vote["model"] ].compact_blank.join(":")
      [ review_kind, panel_id, member.presence || "member-#{vote['step_id']}" ].join(":")
    end

    def self.evidence_digest(vote)
      canonical = vote.to_h.stringify_keys.except("effective_verdict", "outcome_override_id", "original_verdict")
      Digest::SHA256.hexdigest(JSON.generate(deep_sort(canonical)))
    end

    def self.deep_sort(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [ key, deep_sort(value[key]) ] }
      when Array then value.map { |item| deep_sort(item) }
      else value
      end
    end

    private

    attr_reader :workflow, :collector_step, :review_kind, :panel_id, :reviewed_head_sha, :vote

    def gate_kind = vote["verdict"] == "skipped" ? "reviewer_infrastructure" : "review"
    def gate_identity = self.class.gate_identity(review_kind:, panel_id:, vote:)
    def evidence_digest = self.class.evidence_digest(vote)
  end
end
