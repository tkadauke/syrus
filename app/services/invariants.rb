# The invariant monitor: codified checks over persisted work-engine state
# that should hold at every moment, each returning the violations it finds
# with enough detail for an operator to act on.
#
# Invariants are read-only and deterministic: every check is a pure function
# of the database plus the `now:` it is handed, so the same objects serve the
# periodic monitor (InvariantMonitorJob), the admin API, and the work-engine
# simulator, which can assert them after every simulated tick by passing the
# simulated clock and a Scope limited to the scenario's Jobs:
#
#   report = Invariants.evaluate(now: Time.current, scope: Invariants::Scope.for_jobs(job_ids))
#   report.ok?         # => true when nothing is violated and nothing raised
#   report.violations  # => [Invariants::Violation, ...]
#
# A single check can also be called directly, with option overrides:
#
#   Invariants::RetryStorms.call(now: now, max_failures: 3, window: 30.minutes)
#
# Unlike WorkEngine::Reconciler, an invariant never plans or performs a
# repair. Several deliberately overlap reconciler detectors: the reconciler
# says "this is wrong and here is the fix", the monitor says "this must never
# stay true", and keeps saying it when a repair did not happen.
module Invariants
  UnknownInvariant = Class.new(ArgumentError)
  SEVERITIES = %w[critical warning].freeze
  FINGERPRINT_LIMIT = 200

  def self.registry
    [
      Invariants::LandingProgress,
      Invariants::SlotHolders,
      Invariants::RetryStorms,
      Invariants::FailedBlockers,
      Invariants::ZombieWorkflows
    ].freeze
  end

  def self.keys = registry.map(&:key)

  def self.fetch(key)
    registry.find { |invariant| invariant.key == key.to_s } || raise(UnknownInvariant, key.to_s)
  end

  # `only:` limits evaluation to the named invariant keys; `options:` maps an
  # invariant key to its option overrides (`{ "retry_storms" => { max_failures: 3 } }`).
  # One invariant raising does not hide the others: its error is recorded on
  # the report and evaluation continues.
  def self.evaluate(now: Time.current, scope: Scope.all, only: nil, options: {})
    selected = only.nil? ? registry : Array(only).map { |key| fetch(key) }
    overrides = options.to_h.transform_keys(&:to_s)

    results = selected.map do |invariant|
      invariant_options = overrides.fetch(invariant.key, {}).to_h.symbolize_keys
      effective_options = invariant.defaults.merge(invariant_options)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        violations = invariant.call(now: now, scope: scope, **invariant_options)
        Report::Result.new(invariant: invariant, options: effective_options, violations: violations, error: nil, duration_ms: elapsed_ms(started))
      rescue StandardError => e
        Report::Result.new(invariant: invariant, options: effective_options, violations: [], error: e, duration_ms: elapsed_ms(started))
      end
    end

    Report.new(evaluated_at: now, scope: scope, results: results)
  end

  def self.elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end
  private_class_method :elapsed_ms
end
