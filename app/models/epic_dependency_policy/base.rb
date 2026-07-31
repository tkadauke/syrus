class EpicDependencyPolicy::Base
  POLICIES = {
    "inherit" => "EpicDependencyPolicy::Inherit",
    "linear" => "EpicDependencyPolicy::Linear",
    "nonlinear" => "EpicDependencyPolicy::Nonlinear"
  }.freeze

  def self.for(name)
    POLICIES.fetch(name.to_s).constantize.new
  end

  def resolve(epic)
    raise NotImplementedError
  end

  def validate_proposed_child_graph!(_proposals)
  end

  def reconciliation_dependency_jobs(_epic, _sibling_jobs)
    raise NotImplementedError
  end
end
