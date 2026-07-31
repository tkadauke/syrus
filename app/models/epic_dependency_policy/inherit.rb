class EpicDependencyPolicy::Inherit < EpicDependencyPolicy::Base
  def resolve(epic)
    epic.repository.epic_dependency_policy
  end

  def reconciliation_dependency_jobs(epic, sibling_jobs)
    self.class.for(resolve(epic)).reconciliation_dependency_jobs(epic, sibling_jobs)
  end
end
