module Syrus
  module Plugin
    # Interface for `:grader_type` extension points. Language/framework
    # plugins use this to turn a declarative `.syrus.yml` grader entry like
    # `type: rspec` into one or more concrete shell-backed grader steps.
    module GraderType
      # Phases whose graders carry coverage instrumentation.
      #
      # `review` is the only phase whose workflows run a `coverage_analyze`
      # step, so it is the only phase where the artifact is read. Landing,
      # promotion, and ci graders used to collect coverage that nothing ever
      # looked at -- and landing paid for it twice over, because coverage
      # roughly doubles a suite's wall clock and landing gates a merge on a
      # per-grader deadline. A train that times out on instrumentation it
      # does not need is a train that rebuilds instead of landing.
      COVERAGE_PHASES = %w[review].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      # Resolves a grader entry's configured `coverage` against the phases
      # that entry actually serves. Grader types synthesize one command per
      # entry, so coverage has to be decided per entry rather than per run.
      def coverage_for_phases?(coverage, phases)
        return false unless coverage

        (Array(phases).map(&:to_s) & COVERAGE_PHASES).any?
      end

      module ClassMethods
        def type_name
          raise NotImplementedError, "#{self}.type_name is required"
        end

        def grade_steps(config:, default_failures:)
          raise NotImplementedError, "#{self}.grade_steps is required"
        end
      end

      def type_name
        raise NotImplementedError, "#{self.class}#type_name is required"
      end

      def grade_steps(config:, default_failures:)
        raise NotImplementedError, "#{self.class}#grade_steps is required"
      end
    end
  end
end
