module SyrusCoverage::OnMiss
  # Resolves the `coverage.on_miss` discriminator ("block", "schedule", any
  # other/unset value) to the policy object that knows what to do when
  # SyrusCoverage::AnalyzeStep finds the PR below its coverage threshold.
  REGISTRY = {
    "block" => "SyrusCoverage::OnMiss::Block",
    "schedule" => "SyrusCoverage::OnMiss::Schedule"
  }.freeze

  module_function

  def for(on_miss)
    REGISTRY.fetch(on_miss.to_s, "SyrusCoverage::OnMiss::Warn").constantize.new
  end
end
