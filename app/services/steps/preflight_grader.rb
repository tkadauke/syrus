module Steps
  # Executes one grader command during the preflight health check before the
  # implement step in a MainBranchRepair workflow. Identical to Grader in all
  # respects except that log output lands in a "preflight" subdirectory so it
  # cannot collide with the per-iteration grader logs from the main grade loop.
  class PreflightGrader < Grader
    private

    def grader_log_path(name)
      Pathname.new(".syrus/grade-output/preflight/#{name}.log")
    end
  end
end
