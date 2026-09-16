# Shared lookups for anything that needs to ask `:test_evidence` providers
# about a Workflow's failed grader Steps. Adjudicators::KnownFlakyFailure,
# Adjudicators::IsolatedReproDismissal, and IsolatedReproRecorder (the agent
# repro tool's recording path) all need the same three things: which grader
# Steps in this workflow failed, which tests failed for one of those Steps'
# Runs, and which providers are even registered. Factored out so none of the
# three reimplements the plugin-boundary lookup differently.
module TestEvidenceLookup
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
end
