module WorkIntentScope
  # Resolves the WorkIntent/WorkUnit `scope_type` discriminator ("job",
  # "epic", "repository") to the policy object that knows how to find the
  # jobs it covers.
  REGISTRY = {
    "job" => "WorkIntentScope::JobScope",
    "epic" => "WorkIntentScope::EpicScope",
    "repository" => "WorkIntentScope::RepositoryScope"
  }.freeze

  module_function

  def for(scope_type)
    REGISTRY.fetch(scope_type.to_s, "WorkIntentScope::Base").constantize.new
  end
end
