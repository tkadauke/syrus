module Permissions
  # Effect metadata handed to budget controls.
  #
  # Budgets are not permission grants. This is a one-way, read-only feed: the
  # classified effects, risk, and declared budget dimensions of an invocation
  # that the policy evaluator has already decided. Observers are notified of
  # decisions that were not denied, their return values are ignored, and a
  # failing observer never changes or blocks the decision.
  class EffectMetadata
    Record = Data.define(:capability, :operation, :effects, :risk, :budget_dimensions, :policy) do
      def to_h = { capability:, operation:, effects:, risk:, budget_dimensions:, policy: }
    end

    @observers = {}

    class << self
      def register(name, observer = nil, &block)
        callable = observer || block
        raise ArgumentError, "observer must respond to call" unless callable.respond_to?(:call)

        @observers[name.to_sym] = callable
      end

      def unregister(name) = @observers.delete(name.to_sym)
      def observers = @observers.dup
      def reset! = @observers.clear

      def for(descriptor, decision)
        invocation = decision.invocation
        Record.new(capability: invocation.capability, operation: invocation.operation,
          effects: invocation.effects, risk: invocation.risk,
          budget_dimensions: descriptor.budget_dimensions, policy: decision.policy)
      end

      # Always returns the decision unchanged.
      def notify(descriptor, decision, logger: Rails.logger)
        return decision if decision.deny? || descriptor.budget_dimensions.empty?

        record = self.for(descriptor, decision)
        @observers.each do |name, observer|
          observer.call(record)
        rescue => error
          logger.warn("[permissions] budget observer #{name} failed: #{error.class}")
        end
        decision
      end
    end
  end
end
