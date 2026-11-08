module Steps
  # Executes one grader command during the preflight health check before the
  # implement step in a MainBranchRepair workflow. Identical to Grader in all
  # respects except that log output lands in a "preflight" subdirectory so it
  # cannot collide with the per-iteration grader logs from the main grade loop.
  #
  # Every preflight grader gets its own test database namespace
  # (PreflightGraderPolicy) so concurrent database-using graders cannot share
  # mutable state, and the files it created are removed however the grader
  # ends.
  class PreflightGrader < Grader
    def call
      super
    ensure
      cleanup_database_namespace!
    end

    private

    def database_namespace
      PreflightGraderPolicy.database_namespace(step)
    end

    def env
      super.merge(PreflightGraderPolicy.database_env(database_namespace))
    end

    def cleanup_database_namespace!
      removed = PreflightGraderPolicy.cleanup_database!(workspace.path, database_namespace)
      log("[preflight_grader] removed #{removed.size} test database file(s) for namespace #{database_namespace}") if removed.any?
    rescue StandardError => e
      Rails.logger.warn("[PreflightGrader] database cleanup failed for #{database_namespace}: #{e.class}: #{e.message}")
    end

    def grader_log_path(name)
      Pathname.new(".syrus/grade-output/preflight/#{name}.log")
    end
  end
end
