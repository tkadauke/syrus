# frozen_string_literal: true

module Deploy
  # One convergence loop, used by every phase that waits.
  #
  # The shape is always the same: ask a cheap question, decide converged /
  # still-going / failed, and bound the still-going case. Writing that five
  # times produced five slightly different loops -- one that could spin hot
  # when its backoff was skipped, one that conflated a Job failing in forty
  # seconds with a Job running out of a ten-minute clock, one whose stall
  # report and poll interval were the same knob. Here the loop is written once
  # and each phase supplies only the question.
  #
  # Two deliberate properties:
  #
  # A failure verdict is distinct from a timeout. "This failed" and "this did
  # not finish in time" send an operator to different places, and reporting the
  # second when the first happened sends them looking for a hang that never
  # occurred.
  #
  # The loop reports while it waits. A phase with a long legitimate runtime --
  # a data migration over tens of thousands of rows -- is indistinguishable
  # from a wedged one if nothing is printed until the deadline, and that
  # indistinguishability is what made the old migration timeout feel like the
  # only safe answer.
  class Waiter
    Verdict = Struct.new(:state, :note, :detail, keyword_init: true) do
      def converged? = state == :converged
      def failed? = state == :failed
    end

    class << self
      def converged(note = nil)
        Verdict.new(state: :converged, note: note)
      end

      def pending(note = nil)
        Verdict.new(state: :pending, note: note)
      end

      def failed(note, detail: nil)
        Verdict.new(state: :failed, note: note, detail: detail)
      end
    end

    def initialize(clock:, reporter:, dry_run: false)
      @clock = clock
      @reporter = reporter
      @dry_run = dry_run
    end

    # Nothing in a dry run was created, so every wait would poll a resource
    # that does not exist until its own deadline. What a real deploy waits for
    # is not part of the command stream a dry run exists to produce.
    def skip?
      @dry_run
    end

    # `timeout` bounds the pending state. `poll` is how often the question is
    # asked. `report_every` is how often the operator hears about it, which is
    # deliberately a separate number: asking kubectl every five seconds is
    # cheap, and saying so every five seconds is noise.
    def until(label:, timeout:, poll: 5, report_every: 30, on_timeout: nil)
      return Waiter.converged if skip?

      started_at = @clock.now
      deadline = started_at + timeout
      last_report = started_at
      verdict = nil

      loop do
        verdict = yield
        return verdict if verdict.converged?

        if verdict.failed?
          raise Failure.new("#{label}: #{verdict.note}", detail: verdict.detail)
        end

        elapsed = @clock.now - started_at
        if @clock.now >= deadline
          on_timeout&.call(verdict)
          raise Failure.new(
            "#{label}: not finished after #{Duration.humanize(elapsed.round)}" \
            "#{verdict.note ? " (#{verdict.note})" : ""}",
            detail: verdict.detail
          )
        end

        if @clock.now - last_report >= report_every
          last_report = @clock.now
          @reporter.waiting(verdict.note || label, elapsed: elapsed.round)
        end

        @clock.sleep([ poll, deadline - @clock.now ].min.clamp(0, poll))
      end
    end
  end
end
