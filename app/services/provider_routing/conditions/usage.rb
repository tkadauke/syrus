module ProviderRouting
  module Conditions
    class Usage
      COMPARATORS = {
        "remaining_percent_less_than" => ->(actual, expected) { actual < expected },
        "remaining_percent_less_than_or_equal_to" => ->(actual, expected) { actual <= expected },
        "remaining_percent_greater_than" => ->(actual, expected) { actual > expected },
        "remaining_percent_greater_than_or_equal_to" => ->(actual, expected) { actual >= expected }
      }.freeze
      KEYS = ([ "provider", "states" ] + COMPARATORS.keys).freeze

      def self.evaluate(condition:, job:, now: Time.current)
        new(condition:, job:, now:).evaluate
      end

      def initialize(condition:, job:, now:)
        @condition = condition.to_h.stringify_keys
        @job = job
        @now = now
      end

      def evaluate
        return unconfigured if condition.blank?

        availability = App::ProviderAvailability.for_user(user, provider, now: now, cached: false).to_h.stringify_keys
        usage = availability.fetch("usage", {}).to_h.stringify_keys
        remaining = numeric(usage["remaining_percent"])
        matches = state_matches?(availability["state"]) && comparator_results(remaining).values.all?
        {
          "configured" => true,
          "matched" => matches,
          "expected" => condition,
          "actual" => {
            "provider" => provider,
            "state" => availability["state"] || "available",
            "remaining_percent" => remaining,
            "observed_at" => usage["observed_at"]
          }.compact,
          "predicate_results" => comparator_results(remaining)
        }
      end

      private

      attr_reader :condition, :job, :now

      def user = job&.owner_user || job&.user

      def provider
        condition["provider"].presence || job&.workflow_agent_provider || job&.agent_provider
      end

      def unconfigured
        { "configured" => false, "matched" => true }
      end

      def state_matches?(actual)
        condition["states"].blank? || Array(condition["states"]).map(&:to_s).include?((actual || "available").to_s)
      end

      def comparator_results(actual)
        COMPARATORS.each_with_object({}) do |(key, comparator), results|
          next unless condition.key?(key)

          expected = numeric(condition[key])
          results[key] = actual.present? && expected.present? && comparator.call(actual, expected)
        end
      end

      def numeric(value)
        Float(value) if value.present?
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
