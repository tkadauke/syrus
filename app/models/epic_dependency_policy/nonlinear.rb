class EpicDependencyPolicy::Nonlinear < EpicDependencyPolicy::Base
  def resolve(epic)
    "nonlinear"
  end

  def reconciliation_dependency_jobs(_epic, sibling_jobs)
    sibling_jobs
  end
end
