# Selects graders by phase. The command is part of the grader entry itself;
# workflow context only decides which configured phase is active.
class LandingGraderPlan
  CI_TRIGGER_KINDS = %w[ ci_failure main_grader ].freeze
  LANDING_TRIGGER_KINDS = %w[
    auto_merge
    merge_train
    landing_validation
    merge_train_validation
    external_pr_merge
  ].freeze
  # hotfix_sync reuses the `promotion` grade phase — there is no separate
  # built-in `hotfix_sync` entry in `SyrusYml::GRADE_PHASES` yet, and the
  # plan's own default ("use `promotion` when that phase exists, else
  # `landing`") already points hotfix-sync graders at the same phase name
  # promotion uses. A repository opts a grader into both ref-movement
  # workflows with the same `phases: [promotion]`.
  PROMOTION_TRIGGER_KINDS = %w[ promotion hotfix_sync ].freeze

  def self.effective(plan, trigger_kind:, iteration:)
    new(plan, trigger_kind: trigger_kind, iteration: iteration).effective
  end

  def self.landing(plan)
    new(plan, trigger_kind: "auto_merge", iteration: 1).effective
  end

  def self.phase_for(trigger_kind:, iteration:)
    new(nil, trigger_kind: trigger_kind, iteration: iteration).phase
  end

  def initialize(plan, trigger_kind:, iteration:)
    @plan = plan
    @trigger_kind = trigger_kind.to_s
    @iteration = iteration.to_i
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
    return :landing if LANDING_TRIGGER_KINDS.include?(trigger_kind)
    return :promotion if PROMOTION_TRIGGER_KINDS.include?(trigger_kind)

    :review
  end

  private

  attr_reader :plan, :trigger_kind, :iteration
end
