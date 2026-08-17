module RspecCiOnlyPolicy
  module_function

  # Whether the current rspec process should include specs tagged
  # `ci_only: true`. An explicit RUN_CI_ONLY_SPECS (true or false) always
  # wins; otherwise fall back to ambient CI, since GitHub Actions sets
  # CI=true on every job and a bare `bin/rspec` there should still run
  # ci_only specs. bin/rspec-fast relies on the explicit override to force
  # exclusion during the parallel main pass even when CI=true — ci_only
  # specs that mutate schema in-process are only safe in bin/rspec-ci's
  # dedicated, isolated, serial pass.
  def include_ci_only?(env = ENV)
    explicit = env["RUN_CI_ONLY_SPECS"].to_s
    return explicit == "true" if explicit != ""

    env["CI"].to_s != ""
  end
end
