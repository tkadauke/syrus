module Workflows
  class ReviewGateRegistry
    class InvalidContribution < ArgumentError; end

    Definition = Data.define(
      :key, :step_kind, :slot, :before, :after, :excluded_trigger_kinds, :enabled_resolver,
      :loop_budget, :repair_step, :handler_provider, :prompt_provider,
      :tool_provider, :verdict_artifact, :exit_verdicts, :failure_policy,
      :evidence_metadata, :panel_capable
    ) do
      def initialize(key:, step_kind:, slot: "after_agent", before: [], after: [], excluded_trigger_kinds: [],
                     enabled_resolver:, loop_budget:, repair_step: nil,
                     handler_provider:, prompt_provider:, tool_provider:,
                     verdict_artifact:, exit_verdicts: %w[approved skipped],
                     failure_policy: {}, evidence_metadata: {}, panel_capable: false)
        super(
          key: key.to_s, step_kind: step_kind.to_s, slot: slot.to_s,
          before: Array(before).map(&:to_s).freeze,
          after: Array(after).map(&:to_s).freeze,
          excluded_trigger_kinds: Array(excluded_trigger_kinds).map(&:to_s).freeze,
          enabled_resolver: enabled_resolver, loop_budget: loop_budget,
          repair_step: repair_step, handler_provider: handler_provider,
          prompt_provider: prompt_provider, tool_provider: tool_provider,
          verdict_artifact: verdict_artifact.to_s,
          exit_verdicts: Array(exit_verdicts).map(&:to_s).freeze,
          failure_policy: failure_policy.to_h.freeze,
          evidence_metadata: evidence_metadata.to_h.freeze,
          panel_capable: panel_capable == true
        )
      end

      def enabled?(context)
        !excluded_trigger_kinds.include?(context.fetch(:trigger_kind).to_s) && enabled_resolver.call(**context) == true
      end

      def budget(context)
        value = loop_budget.respond_to?(:call) ? loop_budget.call(**context) : loop_budget
        Integer(value)
      end

      def repair_step_for(context)
        value = repair_step.respond_to?(:call) ? repair_step.call(**context) : repair_step
        value.presence || context.fetch(:agent_step)
      end

      def snapshot
        {
          "key" => key, "step_kind" => step_kind, "slot" => slot,
          "verdict_artifact" => verdict_artifact,
          "exit_verdicts" => exit_verdicts, "failure_policy" => failure_policy,
          "evidence_metadata" => evidence_metadata, "panel_capable" => panel_capable
        }
      end
    end

    BUILT_INS = [
      {
        key: "adversarial", step_kind: "adversarial_review", before: %w[security],
        enabled_resolver: ->(job:, syrus_yml:, **) { Base.adversarial_review_rounds(job, syrus_yml: syrus_yml).positive? },
        loop_budget: ->(job:, syrus_yml:, **) { Base.adversarial_review_rounds(job, syrus_yml: syrus_yml) },
        handler_provider: "Steps::AdversarialReview", prompt_provider: "Prompts::AdversarialReview",
        tool_provider: %w[submit_adversarial_review], verdict_artifact: "adversarial_review_iterations",
        failure_policy: { "deterministic" => "fail", "transient" => "retry" }, panel_capable: true
      },
      {
        key: "security", step_kind: "security_review", after: %w[adversarial],
        enabled_resolver: ->(job:, syrus_yml:, **) { Base.security_review_rounds(job, syrus_yml: syrus_yml).positive? },
        loop_budget: ->(job:, syrus_yml:, **) { Base.security_review_rounds(job, syrus_yml: syrus_yml) },
        handler_provider: "Steps::SecurityReview", prompt_provider: "Prompts::SecurityReview",
        tool_provider: %w[submit_security_review], verdict_artifact: "security_review_iterations",
        failure_policy: { "deterministic" => "fail", "transient" => "retry" }, panel_capable: true
      },
      {
        key: "visual", step_kind: "visual_review", after: %w[security],
        excluded_trigger_kinds: %w[external_pr_feedback],
        enabled_resolver: lambda { |job:, syrus_yml:, **|
          plan = syrus_yml ? RepoVisualReviewPlan.for_job(job, loaded: syrus_yml) : RepoVisualReviewPlan.for_job(job)
          plan.enabled? && plan.rounds.positive?
        },
        loop_budget: lambda { |job:, syrus_yml:, **|
          (syrus_yml ? RepoVisualReviewPlan.for_job(job, loaded: syrus_yml) : RepoVisualReviewPlan.for_job(job)).rounds
        },
        handler_provider: "Steps::VisualReview", prompt_provider: "Prompts::VisualReview",
        tool_provider: %w[submit_visual_review], verdict_artifact: "visual_review_iterations",
        failure_policy: { "deterministic" => "fail", "transient" => "retry" }
      }
    ].freeze

    class << self
      def for(slot:, job:, agent_step:, trigger_kind:, syrus_yml: nil)
        context = { job: job, agent_step: agent_step.to_s, trigger_kind: trigger_kind.to_s, syrus_yml: syrus_yml }
        ordered(slot).select { |definition| definition.enabled?(context) && definition.budget(context).positive? }
      end

      def active_for_step_kind(step_kind)
        definitions.find { |definition| definition.step_kind == step_kind.to_s }
      end

      def enabled_for_step_kind(step_kind, job:, agent_step:, trigger_kind:, syrus_yml: nil)
        definition = active_for_step_kind(step_kind)
        return false unless definition

        context = { job: job, agent_step: agent_step.to_s, trigger_kind: trigger_kind.to_s, syrus_yml: syrus_yml }
        definition.enabled?(context) && definition.budget(context).positive?
      end

      # A contribution is resolved again between iterations. Keep the repair
      # reaction to the verdict that already ran, but do not invoke a provider
      # that was disabled or removed in the meantime.
      def continuation_steps(loop_steps:, snapshotted_step_kinds:, job:, trigger_kind:, syrus_yml: nil)
        steps = Array(loop_steps).map(&:to_s)
        review_kind = steps.last
        return steps unless Array(snapshotted_step_kinds).map(&:to_s).include?(review_kind)
        return steps if enabled_for_step_kind(
          review_kind,
          job: job,
          agent_step: steps.first,
          trigger_kind: trigger_kind,
          syrus_yml: syrus_yml
        )

        steps.first(steps.size - 1)
      end

      def ordered(slot)
        candidates = definitions.select { |definition| definition.slot == slot.to_s }
        topological_sort(candidates)
      end

      def definitions
        raw = BUILT_INS + Syrus::PluginRegistry.providers_for(:review_gate).flat_map do |provider|
          Array(provider.review_gates)
        end
        raw.map { |attributes| build(attributes) }.tap { |items| validate_unique!(items) }
      end

      private

      def build(attributes)
        definition = Definition.new(**attributes.to_h.symbolize_keys)
        raise InvalidContribution, "unknown review gate slot #{definition.slot.inspect}" unless Syrus::Plugin::ReviewGate::SLOTS.include?(definition.slot)
        raise InvalidContribution, "review gate key is required" if definition.key.blank?
        raise InvalidContribution, "review gate step_kind is required" if definition.step_kind.blank?
        raise InvalidContribution, "review gate verdict_artifact is required" if definition.verdict_artifact.blank?
        %i[enabled_resolver handler_provider prompt_provider tool_provider].each do |field|
          raise InvalidContribution, "review gate #{definition.key} requires #{field}" if definition.public_send(field).blank?
        end
        definition
      rescue KeyError => e
        raise InvalidContribution, e.message
      end

      def validate_unique!(definitions)
        %i[key step_kind].each do |field|
          duplicate = definitions.group_by { |item| item.public_send(field) }.find { |_key, values| values.many? }
          raise InvalidContribution, "duplicate review gate #{field} #{duplicate.first.inspect}" if duplicate
        end
      end

      def topological_sort(items)
        by_key = items.index_by(&:key)
        edges = items.to_h { |item| [ item.key, Set.new ] }
        items.each do |item|
          item.before.each { |key| edges[item.key] << key if by_key.key?(key) }
          item.after.each { |key| edges[key] << item.key if by_key.key?(key) }
        end
        incoming = items.to_h { |item| [ item.key, 0 ] }
        edges.each_value { |targets| targets.each { |target| incoming[target] += 1 } }
        ready = items.map(&:key).select { |key| incoming[key].zero? }
        result = []
        until ready.empty?
          key = ready.shift
          result << by_key.fetch(key)
          edges.fetch(key).each do |target|
            incoming[target] -= 1
            ready << target if incoming[target].zero?
          end
        end
        raise InvalidContribution, "review gate ordering cycle in slot #{items.first&.slot}" unless result.size == items.size
        result
      end
    end
  end
end
