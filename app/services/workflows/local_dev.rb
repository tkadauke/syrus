module Workflows
  # Local checkout -> local diff.
  #
  #   prepare -> implement
  #
  # This is the no-GitHub development path. It uses the same prepare
  # and implement handlers as issue-driven work, but stops before any
  # summarize / PR-opening step. The CLI reads the implement run's
  # stored three-dot diff and writes it to stdout or a file.
  class LocalDev < Base
    steps :prepare, :implement

    def self.trigger_kind = "local_dev"
  end
end
