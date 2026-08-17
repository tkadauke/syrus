# Chooses which command each grader runs. There are two: `run:` (the everyday
# command, already parallel) and `ci:` (the same parallel run plus the isolated
# serial :ci_only pass). `ci:` is used for ci_failure workflows and main-branch
# graders, which are the two contexts that must also cover :ci_only specs.
#
# There used to be a third, `fast:`, selected for landing trigger kinds and for
# repeat grade-loop iterations. It existed because `run:` was serial, so the
# first pass of every workflow — the common case — ran single-threaded while
# only retries got parallelism. `run:` is parallel now, so the distinction only
# created drift: thirteen trigger kinds were in neither list and never reached
# the fast path at all.
class LandingGraderPlan
  CI_TRIGGER_KINDS = %w[ ci_failure main_grader ].freeze

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
          "ci_command" => grader.ci_command,
          "command_variant" => variant.to_s,
          "ci_variant" => variant == :ci && grader.ci_command.present?
        }.compact

        grader.with(command: command, metadata: metadata)
      end
    )
  end

  def variant
    CI_TRIGGER_KINDS.include?(trigger_kind) ? :ci : :normal
  end

  private

  attr_reader :plan, :trigger_kind, :iteration
end
