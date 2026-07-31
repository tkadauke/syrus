class EpicDependencyPolicy::Nonlinear < EpicDependencyPolicy::Base
  def resolve(epic)
    "nonlinear"
  end
end
