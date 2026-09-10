class TargetGraph
  # One explicit graph fragment returned by a build-system graph provider.
  # Providers return already-normalized TargetGraph::Project and
  # TargetGraph::Target objects so core does not need to understand each build
  # system's vocabulary.
  Import = Data.define(:projects, :targets, :diagnostics) do
    def initialize(projects: [], targets: [], diagnostics: nil)
      projects = Array(projects)
      targets = Array(targets)

      unless projects.all? { |project| project.is_a?(TargetGraph::Project) }
        raise ArgumentError, "projects must all be TargetGraph::Project instances"
      end
      unless targets.all? { |target| target.is_a?(TargetGraph::Target) }
        raise ArgumentError, "targets must all be TargetGraph::Target instances"
      end

      super(projects: projects, targets: targets, diagnostics: diagnostics)
    end
  end
end
