module Workflows
  # Resolves plugin contributions at the three workflow-owned composition
  # positions. Contributions describe shape and policy; Step::Kind continues
  # to own handlers and persisted execution semantics.
  class CompositionAnchors
    InvalidContribution = Class.new(ArgumentError)

    Judge = Data.define(:plugin, :provider, :step_kind, :order, :trigger_kinds, :rounds_for)
    PositionedStep = Data.define(:plugin, :provider, :step_kind, :order, :enabled_for, :fail_policy)

    class << self
      def judges(job:, trigger_kind:, agent_step:)
        contributions(:judge, :judges, Judge).filter_map do |judge|
          next unless judge.trigger_kinds.include?(trigger_kind.to_s)

          rounds = invoke(judge, :judge, :rounds_for, job, default: 0)
          next unless rounds.positive?

          Workflows::Loop.new(max_iterations: rounds, steps: [ agent_step, judge.step_kind ])
        end
      end

      def post_implementation(job:)
        positioned_steps(:post_implementation, job)
      end

      def post_pr(job:)
        positioned_steps(:post_pr, job)
      end

      private

      def positioned_steps(anchor, job)
        contributions(anchor, anchor, PositionedStep).filter_map do |contribution|
          next unless invoke(contribution, anchor, :enabled_for, job, default: false) == true

          contribution.step_kind
        end
      end

      def contributions(anchor, operation, type)
        extension_point = "workflow:#{anchor}"
        Syrus::PluginRegistry.providers_with_owner_for(extension_point).flat_map do |plugin, provider|
          provider = provider.constantize if provider.is_a?(String)
          result = Syrus::PluginInvocation.call(
            extension_point:, provider:, operation:, on_decline: []
          ) { provider.public_send(operation) }
          Array(Syrus::PluginInvocation.value(result)).filter_map do |attributes|
            build(type, plugin, provider, attributes, anchor)
          rescue InvalidContribution => e
            Syrus::PluginRegistry.add_validation_error(plugin, e.message)
            nil
          end
        end.sort_by { |contribution| [ contribution.order, contribution.plugin, contribution.step_kind ] }
      end

      def build(type, plugin, provider, attributes, anchor)
        attrs = attributes.to_h.symbolize_keys
        contribution = if type == Judge
          Judge.new(
            plugin:, provider:, step_kind: attrs.fetch(:step_kind).to_s,
            order: Integer(attrs.fetch(:order, 100)),
            trigger_kinds: Array(attrs.fetch(:trigger_kinds)).map(&:to_s).freeze,
            rounds_for: attrs.fetch(:rounds_for)
          )
        else
          PositionedStep.new(
            plugin:, provider:, step_kind: attrs.fetch(:step_kind).to_s,
            order: Integer(attrs.fetch(:order, 100)),
            enabled_for: attrs.fetch(:enabled_for),
            fail_policy: attrs.fetch(:fail_policy, :default).to_sym
          )
        end
        validate!(contribution, anchor)
      rescue KeyError, ArgumentError, TypeError => e
        raise InvalidContribution, "#{plugin} has an invalid #{anchor} workflow contribution: #{e.message}"
      end

      def validate!(contribution, anchor)
        entry = Step::Kind.fetch(contribution.step_kind)
        if contribution.is_a?(Judge)
          raise InvalidContribution, "#{contribution.plugin} judge rounds_for must be callable" unless contribution.rounds_for.respond_to?(:call)
          raise InvalidContribution, "#{contribution.plugin} judge requires trigger_kinds" if contribution.trigger_kinds.empty?
        else
          raise InvalidContribution, "#{contribution.plugin} #{anchor} enabled_for must be callable" unless contribution.enabled_for.respond_to?(:call)
          if contribution.fail_policy != entry.fail_policy
            raise InvalidContribution,
              "#{contribution.plugin} #{anchor} fail_policy must match Step::Kind #{contribution.step_kind.inspect}"
          end
        end
        contribution
      rescue ArgumentError => e
        raise InvalidContribution, "#{contribution.plugin} #{anchor} names #{e.message}"
      end

      def invoke(contribution, anchor, callable, job, default:)
        callback = contribution.public_send(callable)
        result = Syrus::PluginInvocation.call(
          extension_point: "workflow:#{anchor}", provider: contribution.provider,
          operation: callable, on_decline: default
        ) do
          value = callback.call(job)
          callable == :rounds_for ? Integer(value) : value
        end
        Syrus::PluginInvocation.value(result)
      end
    end
  end
end
