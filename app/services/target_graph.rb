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

  # `root_project`, when given, replaces the default implicit root Project
  # (label "Repository", no kind) -- how TargetGraph::Compiler represents an
  # explicit `project:` block declared in the root `.syrus.yml`. It must
  # still identify the root: id `ROOT_PROJECT_ID` and an empty path. This is
  # a defensive invariant of the graph itself, not just of the compiler that
  # usually builds one -- a caller passing a mismatched root project gets a
  # clear error here instead of a confusing "target references unknown
  # project" failure when the root target is seeded next.
  def initialize(root_project: nil)
    @projects = {}
    @targets = {}
    seed_implicit_root!(root_project)
  end

  def add_project(project)
    raise ValidationError, "project id #{project.id.inspect} is already declared" if @projects.key?(project.id)

    @projects[project.id] = project
    self
  end

  def replace_project(project)
    raise ValidationError, "project id #{project.id.inspect} is not declared" unless @projects.key?(project.id)

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

  def replace_target(target)
    key = target.label.to_s
    raise ValidationError, "target #{key} is not declared" unless @targets.key?(key)
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

  def dependency_closure_for(label)
    label = label.to_s
    seen = []
    collect_dependencies(label, seen)
    seen
  end

  def prepare_dependencies_for(label)
    dependency_closure_for(label).filter_map do |dependency_label|
      dependency = target(dependency_label)
      dependency if dependency&.kind == "prepare" && dependency.executable?
    end
  end

  def source_scopes_for(labels)
    Array(labels).filter_map { |label| target(label)&.source_scope }.flatten.uniq
  end

  # One target's affected-by-diff verdict, with a human-readable `reason`
  # naming which scope decided it (its own, a dependency's, or "repo-wide"
  # for a declaration with no file selector at all) -- callers such as
  # Steps::GraderFanout's logging use this to explain a selection or a skip
  # by target label instead of a bare yes/no.
  Selection = Data.define(:target, :affected, :reason)

  # DOC-20's "Target And Project Selection" pipeline stage: changed files ->
  # affected projects by declaration scope -> affected targets by source
  # scope and dependency closure. A target is affected when:
  #
  #   - it declares no source scope at all -- a root declaration with no
  #     file selector stays repo-wide, the same as legacy
  #     `when_files_changed`-less behavior always has (see
  #     TargetGraph::Compiler#scoped_source_scope: only a root declaration
  #     can end up with an empty scope; every nested declaration defaults to
  #     its own directory);
  #   - its own source scope (already resolved relative to the `.syrus.yml`
  #     that declared it) matches one of the changed files; or
  #   - a target in its dependency closure has a non-empty source scope that
  #     matches one of the changed files. A dependency with an empty scope
  #     (e.g. the implicit root target every legacy declaration depends on)
  #     never counts -- otherwise every target would be "affected" through
  #     that one universal edge.
  #
  # `label` may be a TargetGraph::Label or its string form. An unknown label
  # is reported as unaffected rather than raising -- callers already surface
  # "unknown target" as a validation error elsewhere (see #validate!).
  def affected(label, changed_files:)
    found = target(label)
    return Selection.new(target: nil, affected: false, reason: "unknown target #{label}") unless found

    changed_files = Array(changed_files).map(&:to_s)
    return Selection.new(target: found, affected: true, reason: "repo-wide (no source scope declared)") if found.source_scope.empty?
    if scope_matches?(found.source_scope, changed_files)
      return Selection.new(target: found, affected: true, reason: "own source scope matched a changed file")
    end

    dependency_closure_for(label).each do |dependency_label|
      dependency = target(dependency_label)
      next unless dependency&.source_scope&.any?

      if scope_matches?(dependency.source_scope, changed_files)
        return Selection.new(target: found, affected: true, reason: "dependency #{dependency_label} source scope matched a changed file")
      end
    end

    Selection.new(target: found, affected: false, reason: "no matching files changed")
  end

  # Every executable target of the given kind(s) (formatter, generator,
  # builder, grader, ...) across the whole graph -- root project and every
  # nested project alike -- each paired with its #affected verdict. Callers
  # that only want the affected subset can filter on `.affected`.
  def affected_targets(kind:, changed_files:)
    changed_files = Array(changed_files).map(&:to_s)
    executable_targets_of_kind(kind).map { |candidate| affected(candidate.label, changed_files: changed_files) }
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

  def executable_targets_of_kind(kind)
    kinds = Array(kind).map(&:to_s)
    @targets.values.select { |candidate| kinds.include?(candidate.kind) && candidate.executable? }
  end

  def scope_matches?(patterns, changed_files)
    changed_files.any? { |file| patterns.any? { |pattern| File.fnmatch(pattern, file, File::FNM_DOTMATCH) } }
  end

  def missing_dependency_errors
    @targets.each_value.flat_map do |declared_target|
      declared_target.dependencies.reject { |dependency| @targets.key?(dependency.to_s) }
        .map { |dependency| "target #{declared_target.label} (#{owner_description(declared_target)}) depends on unknown target #{dependency}" }
    end
  end

  def owner_description(target)
    target.owner_config_path || "no owning .syrus.yml"
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

  def collect_dependencies(label, seen)
    Array(@targets[label]&.dependencies).each do |dependency|
      dependency_label = dependency.to_s
      next if seen.include?(dependency_label)

      seen << dependency_label
      collect_dependencies(dependency_label, seen)
    end
  end

  def seed_implicit_root!(custom_root_project)
    if custom_root_project
      unless custom_root_project.id == ROOT_PROJECT_ID
        raise ValidationError, "root project id must be #{ROOT_PROJECT_ID.inspect}; got #{custom_root_project.id.inspect}"
      end
      unless custom_root_project.path == ""
        raise ValidationError, "root project path must be empty; got #{custom_root_project.path.inspect}"
      end
    end

    add_project(custom_root_project || Project.new(id: ROOT_PROJECT_ID, label: "Repository", path: ""))
    add_target(Target.new(label: self.class.root_label, kind: "default", project_id: ROOT_PROJECT_ID))
  end
end
