class LandingGraderPlan
  FAST_TRIGGER_KINDS = %w[
    auto_merge
    ci_failure
    main_branch_repair
    main_grader
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

  def initialize(plan, trigger_kind:, iteration:)
    @plan = plan
    @trigger_kind = trigger_kind.to_s
    @iteration = iteration.to_i
  end

  def effective
    plan.with(
      graders: plan.graders.map do |grader|
        command = grader.command_for(fast: fast?)
        metadata = {
          "standard_command" => grader.command,
          "fast_command" => grader.fast_command,
          "fast_variant" => fast? && grader.fast_command.present?
        }.compact

        grader.with(command: command, metadata: metadata)
      end
    )
  end

  private

  attr_reader :plan, :trigger_kind, :iteration

  def fast?
    FAST_TRIGGER_KINDS.include?(trigger_kind) ||
      (iteration > 1 && REPEAT_FAST_TRIGGER_KINDS.include?(trigger_kind))
  end
end
