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

  def self.effective(plan, trigger_kind:, iteration:, repository: nil, job: nil)
    new(plan, trigger_kind: trigger_kind, iteration: iteration, repository: repository, job: job).effective
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

  def self.phase_for(trigger_kind:, iteration:, repository: nil, job: nil)
    new(nil, trigger_kind: trigger_kind, iteration: iteration, repository: repository, job: job).phase
  end

  def initialize(plan, trigger_kind:, iteration:, repository: nil, job: nil)
    @plan = plan
    @trigger_kind = trigger_kind.to_s
    @iteration = iteration.to_i
    @repository = repository
    @job = job
  end

  def effective
    phase = self.phase
    plan.with(
      graders: plan.graders.select { |grader| grader.phases.include?(phase.to_s) }.map do |grader|
        metadata = {
          "phase" => phase.to_s,
          "configured_phases" => grader.phases
        }.compact

        grader.with(metadata: grader.metadata.merge(metadata))
      end
    )
  end

  def phase
    return :ci if CI_TRIGGER_KINDS.include?(trigger_kind)
    return :promotion if PROMOTION_TRIGGER_KINDS.include?(trigger_kind)
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

  attr_reader :plan, :trigger_kind, :iteration, :repository, :job
end
