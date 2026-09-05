# Internal graph model for DOC-20 (Target Graphs for Project-Aware
# Workflows). A TargetGraph holds Projects (operator-facing workflow
# boundaries) and Targets (execution graph nodes: graders, formatters,
# builders, generators, prepare actions, repo checks, ...) addressed by
# canonical Buck-style labels (see TargetGraph::Label).
#
# This is service-code only: nothing here reads a repository's actual
# `.syrus.yml`, and nothing here changes grader selection. Every graph
# gets an implicit root project/target (`//:repo`) so a repository with
# no monorepo configuration still has a valid, non-empty graph.
class TargetGraph
  Error = Class.new(StandardError)
  ValidationError = Class.new(Error)

  ROOT_PROJECT_ID = "repo".freeze
  ROOT_TARGET_NAME = "repo".freeze

  attr_reader :projects, :targets

  def self.root_label
    Label.root(ROOT_TARGET_NAME)
  end

  def initialize
    @projects = {}
    @targets = {}
    seed_implicit_root!
  end

  def add_project(project)
    raise ValidationError, "project id #{project.id.inspect} is already declared" if @projects.key?(project.id)

    @projects[project.id] = project
    self
  end

  def add_target(target)
    key = target.label.to_s
    raise ValidationError, "target #{key} is already declared" if @targets.key?(key)
    unless @projects.key?(target.project_id)
      raise ValidationError, "target #{key} references unknown project #{target.project_id.inspect}"
    end

    @targets[key] = target
    self
  end

  def project(id)
    @projects[id.to_s]
  end

  def target(label)
    @targets[label.to_s]
  end

  def targets_for_project(project_id)
    project_id = project_id.to_s
    @targets.values.select { |candidate| candidate.project_id == project_id }
  end

  def root_project
    project(ROOT_PROJECT_ID)
  end

  def root_target
    target(self.class.root_label)
  end

  # Confirms the graph is internally consistent: every declared dependency
  # label resolves to a real target, and the dependency edges contain no
  # cycles. Collects every problem instead of raising on the first one so
  # a repository author fixing `.syrus.yml` sees the whole picture at once.
  def validate!
    errors = missing_dependency_errors + cycle_errors
    raise ValidationError, errors.join("; ") if errors.any?

    true
  end

  def cycles
    found = []
    @targets.each_key { |label| find_cycles_from(label, [], found) }
    found.uniq { |cycle| canonical_cycle_key(cycle) }
  end

  private

  def missing_dependency_errors
    @targets.each_value.flat_map do |declared_target|
      declared_target.dependencies.reject { |dependency| @targets.key?(dependency.to_s) }
        .map { |dependency| "target #{declared_target.label} depends on unknown target #{dependency}" }
    end
  end

  def cycle_errors
    cycles.map { |cycle| "dependency cycle: #{cycle.join(' -> ')}" }
  end

  def find_cycles_from(label, path, found)
    return unless @targets.key?(label)

    if (index = path.index(label))
      found << [ *path[index..], label ]
      return
    end

    Array(@targets[label]&.dependencies).each do |dependency|
      find_cycles_from(dependency.to_s, [ *path, label ], found)
    end
  end

  def canonical_cycle_key(cycle)
    nodes = cycle[0...-1]
    rotations = nodes.each_index.map { |index| nodes.rotate(index) }
    rotations.min.join("\0")
  end

  def seed_implicit_root!
    add_project(Project.new(id: ROOT_PROJECT_ID, label: "Repository", path: ""))
    add_target(Target.new(label: self.class.root_label, kind: "default", project_id: ROOT_PROJECT_ID))
  end
end
