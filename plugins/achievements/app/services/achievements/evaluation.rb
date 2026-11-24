module Achievements
  # Evaluates one domain event against every definition it triggers. Safe to
  # run any number of times, in any order: the only write is the idempotent
  # Unlock.record!. A failing definition is logged and does not stop the rest.
  class Evaluation
    def self.call(event, registry: Achievements::Registry.default)
      new(event, registry).call
    end

    def initialize(event, registry)
      @event = event
      @registry = registry
    end

    # Returns the unlocks newly created by this event.
    def call
      adapter = EventAdapters.for(@event)
      return [] if adapter.nil?

      @registry.definitions.select { |definition| definition.trigger == @event.name }.filter_map do |definition|
        evaluate(definition, adapter)
      end
    end

    private

    def evaluate(definition, adapter)
      evaluator = evaluator_for(definition)
      return nil if evaluator.nil?

      outcome = evaluator.call(definition, adapter)
      return nil if outcome.nil?

      unlock, created = Unlock.record!(
        definition.key, user_id: outcome.user_id, subject: outcome.subject,
        evidence: outcome.evidence, registry: @registry, at: @event.occurred_at
      )
      created ? unlock : nil
    rescue StandardError => e
      Rails.logger.error("[achievements] evaluating #{definition.key} for #{@event.name} failed: #{e.class}: #{e.message}")
      nil
    end

    def evaluator_for(definition)
      klass = definition.evaluator.safe_constantize
      return klass.new if klass.is_a?(Class) && klass < Evaluators::Base

      Rails.logger.error("[achievements] #{definition.key}: unknown evaluator #{definition.evaluator}")
      nil
    end
  end
end
