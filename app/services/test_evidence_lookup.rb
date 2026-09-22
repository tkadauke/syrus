# Shared lookups for anything that needs to ask `:test_evidence` providers
# about a Workflow's failed grader Steps. Adjudicators::KnownFlakyFailure,
# Adjudicators::IsolatedReproDismissal, and IsolatedReproRecorder (the agent
# repro tool's recording path) all need the same three things: which grader
# Steps in this workflow failed, which tests failed for one of those Steps'
# Runs, and which providers are even registered. Factored out so none of the
# three reimplements the plugin-boundary lookup differently.
module TestEvidenceLookup
  # Bounded, display-ready summary for the job detail run card: how many
  # tests failed, and a first few names/locations/messages to show inline
  # without opening the raw grade log. Kept small deliberately -- this
  # rides in the main job detail payload for every failed grader Run.
  INLINE_TEST_FAILURE_LIMIT = 5

  def self.failed_grader_steps(workflow)
    workflow.steps.select { |candidate| candidate.kind == "grader" && candidate.state == "failed" }
  end

  # Returns an array of {"suite_name" =>, "name" =>, "file_path" =>, "identity" =>}
  # hashes for one grader Step's Run, deduplicated across whichever
  # :test_evidence providers are registered.
  def self.failed_test_cases_for(run, grader_name)
    test_evidence_providers.flat_map do |provider|
      next [] unless provider.respond_to?(:failed_test_cases)

      Array(provider.failed_test_cases(run: run, grader_name: grader_name))
    end.map { |test_case| test_case.to_h.stringify_keys }.uniq { |test_case| [ test_case["suite_name"], test_case["name"] ] }
  end

  def self.test_evidence_providers
    Syrus::PluginRegistry.providers_for(:test_evidence)
  rescue StandardError
    []
  end

  # Returns nil when there is no test-failure data for this run/grader pair
  # (no provider registered, provider has nothing for this grader, or the
  # grader's output wasn't test-shaped) -- the caller shows no summary
  # rather than guessing. Otherwise a hash with a total count plus the
  # first `limit` failures (from `failed_test_cases_for`, so it inherits
  # that method's provider-deduplication and identity sort).
  def self.failed_test_summary_for(run, grader_name, limit: INLINE_TEST_FAILURE_LIMIT)
    return nil if run.nil? || grader_name.blank?

    failures = failed_test_cases_for(run, grader_name)
    return nil if failures.empty?

    {
      "grader_name" => grader_name,
      "failed_count" => failures.size,
      "failures" => failures.first(limit),
      "omitted_count" => [ failures.size - limit, 0 ].max
    }
  end
end
