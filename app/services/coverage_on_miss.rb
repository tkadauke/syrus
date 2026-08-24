module CoverageOnMiss
  # Resolves the `coverage.on_miss` discriminator ("block", "schedule", any
  # other/unset value) to the policy object that knows what to do when
  # Steps::CoverageAnalyze finds the PR below its coverage threshold.
  REGISTRY = {
    "block" => "CoverageOnMiss::Block",
    "schedule" => "CoverageOnMiss::Schedule"
  }.freeze

  module_function

  def for(on_miss)
    REGISTRY.fetch(on_miss.to_s, "CoverageOnMiss::Warn").constantize.new
  end
end
