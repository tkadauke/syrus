# frozen_string_literal: true

module Deploy
  # Every line the operator sees, in one place.
  #
  # The glyph vocabulary is load-bearing and predates this file: `→` is
  # progress, `✓` is a phase that converged, `✗` is a failure, `⚠` is a choice
  # the operator made that this script would not have made for them. Operators
  # grep deploy logs for those marks, so they are a contract, not decoration.
  #
  # Progress goes to stdout and problems to stderr, which keeps `bin/deploy
  # 2>/dev/null` readable and `bin/deploy >/dev/null` useful as an alarm.
  class Reporter
    def initialize(out: $stdout, err: $stderr)
      @out = out
      @err = err
    end

    def step(message)
      @out.puts("→ #{message}")
      @out.flush
    end

    def ok(message)
      @out.puts("✓ #{message}")
      @out.flush
    end

    def warn(message)
      @err.puts("⚠ #{message}")
      @err.flush
    end

    def error(message)
      @err.puts("✗ #{message}")
      @err.flush
    end

    def detail(message)
      return if message.to_s.empty?

      @err.puts(message)
      @err.flush
    end

    def plain(message = "")
      @out.puts(message)
      @out.flush
    end

    # A phase that is still running reports where it is, so a slow deploy and a
    # wedged one look different from the outside. Without this a long
    # migration and a hung migration are the same silence.
    def waiting(label, elapsed:, next_check_in: nil)
      suffix = next_check_in ? "; next check in #{Duration.humanize(next_check_in)}" : ""
      @out.puts("→ #{label} (#{Duration.humanize(elapsed)} elapsed#{suffix})")
      @out.flush
    end
  end
end
