class EpicDependencyPolicy::Inherit < EpicDependencyPolicy::Base
  def resolve(epic)
    epic.repository.epic_dependency_policy
  end
end
