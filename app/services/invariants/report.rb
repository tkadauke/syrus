module Invariants
  # The outcome of one evaluation: a Result per invariant evaluated.
  class Report
    Result = Data.define(:invariant, :options, :violations, :error, :duration_ms) do
      def key = invariant.key
      def ok? = error.nil? && violations.empty?

      def as_json(*)
        {
          key: key,
          title: I18n.t("services.invariants.#{key}.title"),
          options: options.transform_values { |value| value.is_a?(ActiveSupport::Duration) ? value.to_i : value },
          violation_count: violations.length,
          duration_ms: duration_ms,
          error: error && { class: error.class.name, message: error.message.to_s.truncate(500) }
        }
      end
    end

    attr_reader :evaluated_at, :scope, :results

    def initialize(evaluated_at:, scope:, results:)
      @evaluated_at = evaluated_at
      @scope = scope
      @results = results
    end

    def violations = results.flat_map(&:violations)
    def errors = results.select(&:error)
    def ok? = results.all?(&:ok?)

    def as_json(*)
      {
        evaluated_at: evaluated_at.iso8601,
        scope: scope.as_json,
        invariants: results.map(&:as_json),
        violations: violations.map(&:as_json)
      }
    end
  end
end
