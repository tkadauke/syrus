class ProposalJobDependencyRequirements
  TARGET_KEYS = %w[job_id depends_on_job_id].freeze
  PROPOSAL_KEYS = %w[proposal_slug depends_on slug].freeze

  def self.normalize(raw_requirements, depends_on_job_ids: [], depends_on_slugs: [])
    new(raw_requirements, depends_on_job_ids: depends_on_job_ids, depends_on_slugs: depends_on_slugs).normalize
  end

  def self.for_proposal(proposal)
    normalize(proposal.dependency_requirements, depends_on_job_ids: proposal.depends_on_job_ids)
  end

  def self.for_job_id(proposal, job_id)
    for_proposal(proposal).find { |requirement| requirement.fetch("job_id", nil).to_i == job_id.to_i }
  end

  def self.for_proposal_slug(proposal, slug)
    for_proposal(proposal).find { |requirement| requirement.fetch("proposal_slug", nil) == slug.to_s }
  end

  def self.validate!(user:, requirements:, target_job: nil)
    new(nil).validate!(user: user, requirements: requirements, target_job: target_job)
  end

  def initialize(raw_requirements, depends_on_job_ids: [], depends_on_slugs: [])
    @raw_requirements = raw_requirements
    @depends_on_job_ids = depends_on_job_ids
    @depends_on_slugs = depends_on_slugs
  end

  def normalize
    explicit = Array(raw_requirements).map { |entry| normalize_entry(entry) }
    explicit_job_ids = explicit.filter_map { |requirement| requirement["job_id"] }

    bare_job_requirements = Array(depends_on_job_ids).filter_map { |id| Integer(id, exception: false) }
      .uniq
      .reject { |id| explicit_job_ids.include?(id) }
      .map { |id| success_requirement("job_id" => id) }

    (explicit + bare_job_requirements).tap { |requirements| validate_unique_targets!(requirements) }
  end

  def validate!(user:, requirements:, target_job: nil)
    normalized = Array(requirements)
    job_ids = normalized.filter_map { |requirement| requirement["job_id"] }
    jobs_by_id = user.jobs.where(id: job_ids).index_by(&:id)
    missing_job_id = job_ids.find { |job_id| !jobs_by_id.key?(job_id) }
    raise ArgumentError, "unknown job depends_on_job_ids: #{missing_job_id}" if missing_job_id

    normalized.each do |requirement|
      target = if requirement["job_id"]
        jobs_by_id.fetch(requirement.fetch("job_id"))
      elsif requirement["proposal_slug"]
        proposal = ChatProposal.joins(:chat_session).where(chat_sessions: { user_id: user.id }).find_by(slug: requirement.fetch("proposal_slug"))
        raise ArgumentError, "unknown depends_on slug(s): #{requirement.fetch("proposal_slug")}" unless proposal
        unless proposal.syrus_issue? || proposal.job?
          raise ArgumentError, "depends_on slug must reference a Job proposal: #{proposal.slug}"
        end
        if requirement.fetch("satisfaction_mode") == "deployment_stage" && proposal.job_id.blank?
          raise ArgumentError, "deployment-stage dependencies require a materialized upstream Job; #{proposal.slug} is still only a proposal"
        end

        proposal.job
      end

      next unless target

      ProposalDependencyValidator.validate!(
        target,
        satisfaction_mode: requirement.fetch("satisfaction_mode"),
        required_deployment_stage_name: requirement["required_deployment_stage_name"],
        dependent_job: target_job
      )
    end

    true
  end

  private

  attr_reader :raw_requirements, :depends_on_job_ids, :depends_on_slugs

  def normalize_entry(entry)
    return success_requirement("job_id" => Integer(entry, exception: false)) if integerish?(entry)

    source = entry.respond_to?(:to_h) ? entry.to_h.deep_stringify_keys : {}
    job_id = TARGET_KEYS.filter_map { |key| Integer(source[key], exception: false) }.first
    proposal_slug = PROPOSAL_KEYS.filter_map { |key| source[key].to_s.strip.presence }.first
    if job_id.blank? == proposal_slug.blank?
      raise ArgumentError, "each dependency requirement must include exactly one of job_id or proposal_slug"
    end

    satisfaction_mode = source["satisfaction_mode"].to_s.strip.presence || "success"
    unless JobDependency::SATISFACTION_MODES.include?(satisfaction_mode)
      raise ArgumentError, "satisfaction_mode must be one of: #{JobDependency::SATISFACTION_MODES.join(', ')}"
    end

    required_stage = source["required_deployment_stage_name"].to_s.strip.presence
    if satisfaction_mode == "deployment_stage" && required_stage.blank?
      raise ArgumentError, "required_deployment_stage_name is required for deployment-stage dependencies"
    end
    if satisfaction_mode != "deployment_stage" && required_stage.present?
      raise ArgumentError, "required_deployment_stage_name is only allowed for deployment-stage dependencies"
    end

    {
      "job_id" => job_id,
      "proposal_slug" => proposal_slug,
      "satisfaction_mode" => satisfaction_mode,
      "required_deployment_stage_name" => required_stage
    }.compact
  end

  def success_requirement(target)
    target.merge(
      "satisfaction_mode" => "success",
      "required_deployment_stage_name" => nil
    ).compact
  end

  def integerish?(value)
    Integer(value, exception: false).present?
  end

  def validate_unique_targets!(requirements)
    seen = {}
    requirements.each do |requirement|
      key = requirement["job_id"] ? [ "job", requirement["job_id"] ] : [ "proposal", requirement["proposal_slug"] ]
      raise ArgumentError, "duplicate dependency requirement for #{key.last}" if seen[key]

      seen[key] = true
    end
  end
end
