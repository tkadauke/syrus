class EpicDependencyPolicy::Linear < EpicDependencyPolicy::Base
  def resolve(epic)
    "linear"
  end
end
