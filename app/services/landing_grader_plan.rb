class LandingGraderPlan
  FAST_TRIGGER_KINDS = %w[
    auto_merge
    main_branch_repair
    merge_train
  ].freeze

  REPEAT_FAST_TRIGGER_KINDS = %w[
    chat_feedback
    coding_handoff
    initial
    pr_comment
    retry
  ].freeze

  def self.effective(plan, trigger_kind:, iteration:)
    new(plan, trigger_kind: trigger_kind, iteration: iteration).effective
  end

  def self.landing(plan)
    new(plan, trigger_kind: "auto_merge", iteration: 1).effective
  end

  def self.variant_for(trigger_kind:, iteration:)
    new(nil, trigger_kind: trigger_kind, iteration: iteration).variant
  end

  def initialize(plan, trigger_kind:, iteration:)
    @plan = plan
    @trigger_kind = trigger_kind.to_s
    @iteration = iteration.to_i
  end

  def effective
    variant = self.variant
    plan.with(
      graders: plan.graders.map do |grader|
        command = grader.command_for(variant: variant)
        metadata = {
          "standard_command" => grader.command,
          "fast_command" => grader.fast_command,
          "ci_command" => grader.ci_command,
          "command_variant" => variant.to_s,
          "fast_variant" => fast_variant?(grader, variant),
          "ci_variant" => %i[ci ci_or_fast].include?(variant) && grader.ci_command.present?
        }.compact

        grader.with(command: command, metadata: metadata)
      end
    )
  end

  def variant
    return :ci if trigger_kind == "ci_failure"
    return :ci_or_fast if trigger_kind == "main_grader"
    return :fast if fast?

    :normal
  end

  private

  attr_reader :plan, :trigger_kind, :iteration

  def fast_variant?(grader, variant)
    return true if variant == :fast && grader.fast_command.present?

    variant == :ci_or_fast && grader.ci_command.blank? && grader.fast_command.present?
  end

  def fast?
    FAST_TRIGGER_KINDS.include?(trigger_kind) ||
      (iteration > 1 && REPEAT_FAST_TRIGGER_KINDS.include?(trigger_kind))
  end
end
