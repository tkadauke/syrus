# The internal, repository-local graph of Projects and Targets described in
# DOC-20 (Target Graphs for Project-Aware Workflows). This is the pure data
# model and validation layer only: it does not yet compile `.syrus.yml`
# (root or nested) into graph nodes, and nothing reads from it to change
# grader/formatter/build selection behavior. Those come in later slices of
# EPIC-296.
#
# Every graph is seeded with the implicit root project/target (`//:repo`)
# so a repository with only a root `.syrus.yml` — today's only shape — is
# still a valid, non-empty TargetGraph. See DOC-20 "Implicit Projects".
class TargetGraph
  DuplicateProjectError = Class.new(StandardError)
  DuplicateTargetError = Class.new(StandardError)
  UnknownDependencyError = Class.new(StandardError)
  DependencyCycleError = Class.new(StandardError)

  ROOT_PROJECT_ID = "repo".freeze

  def initialize(owner_config_path: SyrusYml::CONFIG_FILE)
    @projects = {}
    add_project(
      Project.new(
        id: ROOT_PROJECT_ID,
        label: Label.root,
        path_scope: "",
        owner_config_path: owner_config_path
      )
    )
  end

  def add_project(project)
    if @projects.key?(project.id)
      raise DuplicateProjectError, "project id #{project.id.inspect} already exists in this graph"
    end

    project.targets.each do |target|
      if find_target(target.label)
        raise DuplicateTargetError, "target label #{target.label} already exists in this graph"
      end
    end

    @projects[project.id] = project
  end

  def projects
    @projects.values
  end

  def project(id)
    @projects[id.to_s]
  end

  def root_project
    @projects[ROOT_PROJECT_ID]
  end

  def targets
    projects.flat_map(&:targets)
  end

  def find_target(label)
    key = Label.coerce(label)
    targets.find { |target| target.label == key }
  end

  # Validates the whole graph: no duplicate target labels, no dependency
  # edge pointing at a label that doesn't exist in this graph, and no
  # dependency cycles. Raises the first violation found; returns true when
  # the graph is well-formed.
  def validate!
    index = {}
    targets.each do |target|
      raise DuplicateTargetError, "duplicate target label #{target.label}" if index.key?(target.label)

      index[target.label] = target
    end

    targets.each do |target|
      target.dependencies.each do |dependency_label|
        unless index.key?(dependency_label)
          raise UnknownDependencyError, "#{target.label} depends on unknown target #{dependency_label}"
        end
      end
    end

    detect_cycles!(index)

    true
  end

  private

  def detect_cycles!(index)
    visiting = {}
    visited = {}

    index.each_key { |label| visit_for_cycle(label, index, visiting, visited, []) }
  end

  def visit_for_cycle(label, index, visiting, visited, stack)
    return if visited[label]

    if visiting[label]
      chain = (stack + [ label ]).join(" -> ")
      raise DependencyCycleError, "dependency cycle detected: #{chain}"
    end

    visiting[label] = true
    index.fetch(label).dependencies.each do |dependency_label|
      visit_for_cycle(dependency_label, index, visiting, visited, stack + [ label ])
    end
    visiting.delete(label)
    visited[label] = true
  end
end
