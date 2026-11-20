# Selects graders by phase. The command is part of the grader entry itself;
# workflow context only decides which configured phase is active.
class LandingGraderPlan
  CI_TRIGGER_KINDS = %w[ ci_failure main_grader main_branch_repair ].freeze
  LANDING_TRIGGER_KINDS = %w[
    auto_merge
    merge_train
    landing_validation
    merge_train_validation
    external_pr_merge
  ].freeze
  # hotfix_sync reuses the `promotion` grade phase — there is no separate
  # built-in `hotfix_sync` phase, and the
  # plan's own default ("use `promotion` when that phase exists, else
  # `landing`") already points hotfix-sync graders at the same phase name
  # promotion uses. A repository opts a grader into both ref-movement
  # workflows with the same `phases: [promotion]`.
  PROMOTION_TRIGGER_KINDS = %w[ promotion hotfix_sync ].freeze
  UNLAND_TRIGGER_KINDS = %w[ unland ].freeze

  def self.effective(plan, trigger_kind:, iteration:, phase: nil, repository: nil, job: nil)
    new(
      plan,
      trigger_kind: trigger_kind,
      iteration: iteration,
      phase: phase,
      repository: repository,
      job: job
    ).effective
  end

  def self.landing(plan, repository: nil, job: nil)
    new(
      plan,
      trigger_kind: "auto_merge",
      iteration: 1,
      repository: repository,
      job: job
    ).effective
  end

  # A required CI-phase grader can opt out of running before merge with
  # `metadata: { landing_parity: false }`. It still runs wherever the CI phase
  # runs (main grading, CI repair, main-branch repair); landing names it as a
  # post-merge delta instead of running it or blocking on it. For a suite too
  # slow or too red to gate a landing on.
  def self.landing_parity?(grader)
    grader.metadata.to_h["landing_parity"] != false
  end

  def self.phase_for(trigger_kind:, iteration:, repository: nil, job: nil)
    new(nil, trigger_kind: trigger_kind, iteration: iteration, repository: repository, job: job).phase
  end

  def initialize(plan, trigger_kind:, iteration:, phase: nil, repository: nil, job: nil)
    @plan = plan
    @trigger_kind = trigger_kind.to_s
    @iteration = iteration.to_i
    @phase_override = phase&.to_sym
    @repository = repository
    @job = job
  end

  def effective
    phase = self.phase
    selected = plan.graders.select { |grader| grader.phases.include?(phase.to_s) }.map do |grader|
      metadata = {
        "phase" => phase.to_s,
        "configured_phases" => grader.phases
      }.compact

      grader.with(metadata: grader.metadata.merge(metadata))
    end

    parity = main_grading_parity_graders(phase, selected)
    plan.with(graders: without_superseded(selected, parity) + parity)
  end

  def phase
    return phase_override if phase_override
    return :ci if CI_TRIGGER_KINDS.include?(trigger_kind)
    return :promotion if PROMOTION_TRIGGER_KINDS.include?(trigger_kind)
    return :unland if UNLAND_TRIGGER_KINDS.include?(trigger_kind)
    return :unland if job.is_a?(Job) && job.rollback? && LANDING_TRIGGER_KINDS.include?(trigger_kind)
    return :landing if repository.nil? && LANDING_TRIGGER_KINDS.include?(trigger_kind)
    return :review if repository.nil?

    policy = DeliveryPolicy.for(repository: repository, job: job)
    configured_phase = if LANDING_TRIGGER_KINDS.include?(trigger_kind)
      policy.landing_grade_phase(job)
    else
      policy.review_grade_phase(job)
    end
    configured_phase.to_sym
  end

  private

  # Landing validates under the contract main grading will apply: a required
  # CI-phase grader that is not already part of the landing phase is added, so
  # the exact SHA is proven against it before merge instead of being left to a
  # post-merge delta. Which of them actually run is still decided by the same
  # target selection (when_files_changed / affected targets). Only ordinary
  # landing (not unland or an explicit phase) is widened.
  def main_grading_parity_graders(phase, selected)
    return [] unless phase_override.nil? && repository && phase == :landing
    return [] unless LANDING_TRIGGER_KINDS.include?(trigger_kind)

    ci_phase = DeliveryPolicy.for(repository: repository, job: job).branch_health_grade_phase(repository.default_branch).to_s
    return [] if ci_phase == phase.to_s

    names = selected.map(&:name)
    plan.graders.select do |grader|
      grader.required && self.class.landing_parity?(grader) && grader.phases.include?(ci_phase) && names.exclude?(grader.name)
    end.map do |grader|
      grader.with(metadata: grader.metadata.merge("phase" => ci_phase, "configured_phases" => grader.phases, "main_grading_parity" => true))
    end
  end

  # A grader type whose CI variant is a superset of its full variant (the
  # same suite plus the CI-only examples) says so with `supersedes`. Running
  # both proves the same examples twice -- the full RSpec suite alone is most
  # of an hour of a merge train -- so the superseded one is dropped, unless
  # it is the only one producing coverage evidence.
  def without_superseded(selected, parity)
    superseding = parity.each_with_object({}) do |grader, by_name|
      name = grader.metadata["supersedes"].to_s
      by_name[name] = grader if name.present?
    end
    return selected if superseding.empty?

    selected.reject do |grader|
      replacement = superseding[grader.name]
      replacement && (!coverage?(grader) || coverage?(replacement))
    end
  end

  def coverage?(grader)
    grader.metadata.dig("filter_capabilities", "coverage") == true
  end

  attr_reader :plan, :trigger_kind, :iteration, :phase_override, :repository, :job
end
