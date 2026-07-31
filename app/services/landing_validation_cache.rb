class LandingValidationCache
  ARTIFACT_KEY = "landing_validation".freeze
  MAX_AGE = 7.days

  Decision = Data.define(:reusable, :reason, :match_type, :artifact, :workflow) do
    def reusable? = reusable
  end

  def self.record!(workflow:, head_sha:, base_sha:, base_ref:, tree_sha: nil, grader_fingerprint: nil, validation_source: "graders")
    workflow.set_artifact!(
      ARTIFACT_KEY,
      {
        "required_graders_passed" => true,
        "head_sha" => head_sha.to_s.presence,
        "tree_sha" => tree_sha.to_s.presence,
        "base_sha" => base_sha.to_s.presence,
        "base_ref" => base_ref.to_s.presence,
        "grader_fingerprint" => grader_fingerprint.to_s.presence,
        "validation_source" => validation_source.to_s.presence,
        "checked_at" => Time.current.iso8601
      }.compact
    )
  end

  def self.decision_for_pr(job:, pr:, tree_sha: nil, grader_fingerprint: nil)
    head_sha = MergeabilityRecorder.head_sha(pr)
    base_sha = MergeabilityRecorder.base_sha(pr)
    base_ref = MergeabilityRecorder.base_ref(pr)

    reusable_for?(
      job: job,
      head_sha: head_sha,
      tree_sha: tree_sha,
      base_sha: base_sha,
      base_ref: base_ref,
      grader_fingerprint: grader_fingerprint
    )
  end

  def self.valid_for?(job:, pr:)
    decision_for_pr(job: job, pr: pr).reusable?
  end

  def self.valid_head_for?(job:, head_sha:)
    reusable_for?(job: job, head_sha: head_sha).reusable?
  end

  def self.reusable_for?(job:, head_sha:, tree_sha: nil, base_sha: nil, base_ref: nil, grader_fingerprint: nil)
    return miss("current head SHA is blank") if head_sha.blank?

    artifacts = validation_artifacts(job)
    return miss("no cached landing validation found") if artifacts.empty?

    stale = nil
    artifacts.each do |entry|
      artifact = entry.fetch(:artifact)
      stale = stale_reason(artifact, base_sha: base_sha, base_ref: base_ref, grader_fingerprint: grader_fingerprint)
      next if stale

      if artifact["head_sha"] == head_sha
        return hit(entry, match_type_for_head(artifact), "head/base/grader configuration match")
      end

      if tree_sha.present? && artifact["tree_sha"].present? && artifact["tree_sha"] == tree_sha
        return hit(entry, "same_tree", "tree/base/grader configuration match")
      end
    end

    miss(stale || "no cached validation matched current head or tree")
  end

  # Did this Job pass required graders at some point (any head/base)?
  # Used by the opt-in clean-rebase carry-forward (Steps::ForcePush) to
  # decide whether there's a green grade worth carrying across a clean
  # rebase under Repository#trust_clean_rebase_grade.
  def self.green_validation_present?(job)
    recorded_workflows(job).any? do |workflow|
      artifact = workflow.artifact(ARTIFACT_KEY)
      artifact.is_a?(Hash) && artifact["required_graders_passed"] == true
    end
  end

  def self.carry_forward_source_for(job:, grader_fingerprint:)
    return miss("current required grader configuration could not be fingerprinted") if grader_fingerprint.blank?

    artifacts = validation_artifacts(job)
    return miss("no cached landing validation found") if artifacts.empty?

    stale = nil
    artifacts.each do |entry|
      artifact = entry.fetch(:artifact)
      next unless artifact["validation_source"].blank? || artifact["validation_source"] == "graders"

      stale = carry_forward_stale_reason(artifact, grader_fingerprint: grader_fingerprint)
      next if stale

      return hit(entry, "clean_rebase_carry_forward_source", "prior required-grader validation matches current grader configuration")
    end

    miss(stale || "no prior required-grader validation matched current grader configuration")
  end

  # Any workflow with a successful grader_collect writes the validation;
  # rebase workflows write it when carrying a green grade across a clean
  # rebase (opt-in). Both are valid sources for skip-on-revalidation.
  def self.recorded_workflows(job)
    job.workflows.reorder(id: :desc)
  end
  private_class_method :recorded_workflows

  def self.validation_artifacts(job)
    recorded_workflows(job).filter_map do |workflow|
      artifact = workflow.artifact(ARTIFACT_KEY)
      next unless artifact.is_a?(Hash) && artifact["required_graders_passed"] == true

      { workflow: workflow, artifact: artifact }
    end
  end
  private_class_method :validation_artifacts

  def self.stale_reason(artifact, base_sha:, base_ref:, grader_fingerprint:)
    return "cached validation is older than #{MAX_AGE.inspect}" if stale_checked_at?(artifact)

    if base_ref.present? && artifact["base_ref"].blank?
      return "cached validation is missing base ref"
    end

    if base_ref.present? && artifact["base_ref"] != base_ref
      return "base ref changed from #{artifact["base_ref"]} to #{base_ref}"
    end

    if base_sha.present? && artifact["base_sha"].blank?
      return "cached validation is missing base SHA"
    end

    if base_sha.present? && artifact["base_sha"] != base_sha
      return "base SHA changed from #{short(artifact["base_sha"])} to #{short(base_sha)}"
    end

    if grader_fingerprint.present? && artifact["grader_fingerprint"].blank?
      return "cached validation is missing required grader configuration"
    end

    if artifact["grader_fingerprint"].present? && grader_fingerprint.blank?
      return "current required grader configuration could not be fingerprinted"
    end

    if grader_fingerprint.present? && artifact["grader_fingerprint"] != grader_fingerprint
      return "required grader configuration changed"
    end

    nil
  end
  private_class_method :stale_reason

  def self.carry_forward_stale_reason(artifact, grader_fingerprint:)
    return "cached validation is older than #{MAX_AGE.inspect}" if stale_checked_at?(artifact)
    return "cached validation is missing required grader configuration" if artifact["grader_fingerprint"].blank?
    return "required grader configuration changed" if artifact["grader_fingerprint"] != grader_fingerprint

    nil
  end
  private_class_method :carry_forward_stale_reason

  def self.stale_checked_at?(artifact)
    checked_at = Time.iso8601(artifact["checked_at"].to_s)
    checked_at < MAX_AGE.ago
  rescue ArgumentError, TypeError
    false
  end
  private_class_method :stale_checked_at?

  def self.match_type_for_head(artifact)
    artifact["validation_source"] == "clean_rebase" ? "clean_rebase_carry_forward" : "exact_head"
  end
  private_class_method :match_type_for_head

  def self.hit(entry, match_type, reason)
    Decision.new(true, reason, match_type, entry.fetch(:artifact), entry.fetch(:workflow))
  end
  private_class_method :hit

  def self.miss(reason)
    Decision.new(false, reason, nil, nil, nil)
  end
  private_class_method :miss

  def self.short(sha)
    sha.to_s.first(7)
  end
  private_class_method :short
end
