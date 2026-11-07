# frozen_string_literal: true

module Deploy
  # Time, injected.
  #
  # Every wait in a deploy is a loop against a deadline, and a loop against a
  # deadline is untestable while it calls Kernel#sleep -- which is how the
  # previous implementation's waits came to be verified by extracting their
  # source text instead of running them. With the clock behind an interface, a
  # spec can drive a fifteen-minute rollout wait in microseconds and assert
  # what the loop actually decided.
  class Clock
    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def sleep(seconds)
      Kernel.sleep(seconds)
      nil
    end

    # A dry run that honoured its backoffs would take as long as a deploy while
    # changing nothing, so nobody would run it -- and the one thing a dry run
    # has to be is worth running.
    class Immediate < Clock
      def sleep(_seconds)
        nil
      end
    end

    # Deterministic time for specs: sleeping advances the clock instead of the
    # process.
    class Fake < Clock
      attr_reader :slept

      def initialize(start: 0.0)
        @now = start
        @slept = []
      end

      def now
        @now
      end

      def sleep(seconds)
        @slept << seconds
        @now += seconds
        nil
      end

      def advance(seconds)
        @now += seconds
      end
    end
  end
end
