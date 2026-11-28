# frozen_string_literal: true

module WorkEngine
  module Simulation
    # Asserts the invariant monitor's invariants (Invariants.registry) on the
    # simulated world after every tick, scoped to the scenario's Jobs.
    #
    # Production thresholds are wall-clock ("stranded for 2 hours"), but a
    # simulated tick takes milliseconds of real time, so a wall-clock
    # threshold would never elapse inside a scenario. The simulator therefore
    # evaluates every invariant with its duration thresholds at zero -- the
    # condition alone counts -- and replaces the threshold with persistence:
    # a violation fails the scenario once the same fingerprint has been
    # reported on `sustain` consecutive ticks. A tick is one reconciler pass,
    # so "held for N ticks" means "N reconciler passes saw it and none
    # repaired it", which is what the production threshold approximates.
    #
    # When the scenario ends quiescent (waiting on an external actor, or
    # stuck because nothing changed), the world can no longer move on its
    # own, so every violation still present counts regardless of how long it
    # has been seen.
    #
    # The retry-storm window is a count over a window rather than an age, and
    # the default hour of real time already spans a whole scenario; it keeps
    # its production value.
    #
    # Scenario YAML can tune this under `invariants:`:
    #
    #   invariants:
    #     only: [zombie_workflows]          # default: every invariant
    #     except: [failed_blockers]
    #     sustain: { landing_progress: 20 } # ticks
    #     options: { retry_storms: { max_failures: 8 } }
    #     expected:                         # violations this scenario models
    #       - invariant: failed_blockers
    #         job: root                     # optional fixture key
    #         discriminator: zombie_workflow # optional prefix
    #         required: true                # fail if it never appears
    #         reason: why this is the point of the scenario
    class InvariantAssertions
      DEFAULT_SUSTAIN_TICKS = {
        "landing_progress" => 10,
        "slot_holders" => 3,
        "retry_storms" => 1,
        "failed_blockers" => 5,
        "zombie_workflows" => 5
      }.freeze
      # Options that keep their production value in simulation (see above).
      KEEP_DURATION_OPTIONS = { "retry_storms" => %i[window] }.freeze
      FALLBACK_SUSTAIN_TICKS = 5

      Expected = Data.define(:invariant, :job_id, :discriminator, :required, :reason) do
        def matches?(violation)
          return false unless violation.invariant == invariant
          return false if discriminator.present? && !violation_conditions(violation).any? { |value| value.to_s.start_with?(discriminator) }
          return true if job_id.nil?

          job_ids = Array(violation.affected_ids["job_ids"]).map(&:to_i)
          job_ids << violation.subject_id.to_i if violation.subject_type == "Job"
          job_ids.include?(job_id.to_i)
        end

        def label = [ invariant, job_id && "job #{job_id}", discriminator ].compact.join(" ")

        private

        def violation_conditions(violation)
          [ violation.discriminator, violation.details["condition"], violation.details["reason"] ].compact
        end
      end

      Streak = Struct.new(:violation, :first_tick, :last_tick)

      # `config` is the scenario's translated `invariants:` block (job keys
      # already resolved to ids).
      def self.build(config, job_ids:)
        config = config.to_h.stringify_keys
        new(
          job_ids: job_ids,
          only: config["only"],
          except: config["except"],
          sustain: config["sustain"],
          options: config["options"],
          expected: config["expected"]
        )
      end

      attr_reader :expected

      def initialize(job_ids:, only: nil, except: nil, sustain: nil, options: nil, expected: nil)
        @scope = Invariants::Scope.for_jobs(job_ids)
        keys = only.present? ? Array(only).map { |key| Invariants.fetch(key).key } : Invariants.keys
        Array(except).each { |key| Invariants.fetch(key) }
        @keys = keys - Array(except).map(&:to_s)
        @sustain = DEFAULT_SUSTAIN_TICKS.merge(sustain.to_h.transform_keys(&:to_s).transform_values(&:to_i))
        @options = build_options(options.to_h.transform_keys(&:to_s))
        @expected = Array(expected).map { |entry| build_expected(entry.to_h.stringify_keys) }
        @expected_seen = Set.new
        @streaks = {}
      end

      # Evaluates once and returns the failure lines for every unexpected
      # violation that has now persisted for its sustain window.
      def observe!(tick)
        report = evaluate
        failures = error_lines(tick, report)
        present = {}
        report.violations.each do |violation|
          fingerprint = violation.fingerprint
          present[fingerprint] = true
          if (expectation = expected.find { |entry| entry.matches?(violation) })
            @expected_seen << expectation
            next
          end

          streak = @streaks[fingerprint] ||= Streak.new(violation, tick, tick)
          streak.violation = violation
          streak.last_tick = tick
          failures << line(violation, streak) if sustained?(streak)
        end
        @streaks.select! { |fingerprint, _| present.key?(fingerprint) }
        failures
      end

      # The end-of-scenario check. A quiescent world stays as it is, so every
      # unexpected violation still present fails; required expectations that
      # never appeared fail too.
      def finish!(tick, quiescent:)
        failures = []
        if quiescent
          report = evaluate
          failures.concat(error_lines(tick, report))
          report.violations.each do |violation|
            if (expectation = expected.find { |entry| entry.matches?(violation) })
              @expected_seen << expectation
              next
            end

            streak = @streaks[violation.fingerprint] || Streak.new(violation, tick, tick)
            failures << line(violation, streak, final: true)
          end
        end
        expected.each do |expectation|
          next unless expectation.required
          next if @expected_seen.include?(expectation)

          failures << "expected invariant violation never observed: #{expectation.label}"
        end
        failures
      end

      private

      attr_reader :scope, :keys, :sustain, :options

      def evaluate
        Invariants.evaluate(now: Time.current, scope: scope, only: keys, options: options)
      end

      def build_options(overrides)
        keys.index_with do |key|
          invariant = Invariants.fetch(key)
          kept = KEEP_DURATION_OPTIONS.fetch(key, [])
          zeroed = invariant.defaults.each_with_object({}) do |(name, value), result|
            result[name] = 0.seconds if value.is_a?(ActiveSupport::Duration) && !kept.include?(name)
          end
          custom = overrides.fetch(key, {}).to_h.to_h do |name, value|
            name = name.to_sym
            default = invariant.defaults[name]
            [ name, default.is_a?(ActiveSupport::Duration) && value.is_a?(Numeric) ? value.seconds : value ]
          end
          zeroed.merge(custom)
        end
      end

      def build_expected(entry)
        key = Invariants.fetch(entry.fetch("invariant")).key
        Expected.new(
          invariant: key,
          job_id: entry["job"],
          discriminator: entry["discriminator"].presence,
          required: entry.fetch("required", false) == true,
          reason: entry["reason"]
        )
      end

      def sustained?(streak)
        streak.last_tick - streak.first_tick + 1 >= sustain.fetch(streak.violation.invariant, FALLBACK_SUSTAIN_TICKS)
      end

      def error_lines(tick, report)
        report.errors.map do |result|
          "tick #{tick}: invariant #{result.key} raised #{result.error.class}: #{result.error.message}"
        end
      end

      def line(violation, streak, final: false)
        span = final ? "still present when the scenario ended (first seen tick #{streak.first_tick})" : "held ticks #{streak.first_tick}..#{streak.last_tick}"
        "tick #{streak.last_tick}: invariant #{violation.invariant} #{violation.fingerprint} #{span}: #{violation.message}"
      end
    end
  end
end
