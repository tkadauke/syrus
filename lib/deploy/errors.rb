# frozen_string_literal: true

module Deploy
  # Raised for anything that should stop the deploy with an operator-readable
  # message rather than a Ruby backtrace. The runner catches it, reports it,
  # unwinds the control stack, and exits non-zero.
  class Failure < StandardError
    attr_reader :detail, :exit_status

    def initialize(message, detail: nil, exit_status: 1)
      super(message)
      @detail = detail
      @exit_status = exit_status
    end
  end

  # The operator asked for something impossible before any cluster was
  # touched -- a bad flag, an unparseable duration. Exits 2 to distinguish
  # "you asked wrong" from "the deploy failed".
  class UsageError < Failure
    def initialize(message, detail: nil)
      super(message, detail: detail, exit_status: 2)
    end
  end

  # Ctrl-C. Separate from Failure so the control stack can decline to undo work
  # that is dangerous to interrupt -- a running migration above all.
  class Interrupted < Failure
    def initialize(message = "deploy interrupted")
      super(message, exit_status: 130)
    end
  end
end
