# An operator-facing workflow boundary inside a TargetGraph: what can be
# previewed, which hooks/visual-review/coverage config applies, and which
# targets are grouped together for display. See DOC-20 "Projects".
#
# Every project owns an implicit default target whose label matches the
# project's own label (e.g. project `//cli:default` owns target
# `//cli:default`, kind "default") — the anchor other targets in the same
# project depend on. Callers may supply that target explicitly (to set a
# non-default kind or metadata); otherwise one is synthesized.
class TargetGraph
  class Project
    InvalidProjectError = Class.new(StandardError)

    attr_reader :id, :label, :kind, :path_scope, :owner_config_path

    def initialize(id:, label:, kind: nil, path_scope: "", owner_config_path: nil, targets: [])
      @id = id.to_s.strip
      raise InvalidProjectError, "project id must not be blank" if @id.empty?

      @label = Label.coerce(label)
      @kind = kind.to_s.strip.presence
      @path_scope = path_scope.to_s.strip
      @owner_config_path = owner_config_path.to_s.strip.presence
      @targets = {}

      Array(targets).each { |target| add_target(target) }
      add_target(Target.new(label: @label, kind: "default", owner_config_path: @owner_config_path)) unless @targets.key?(@label)

      freeze
    end

    def targets
      @targets.values
    end

    def target(label)
      @targets[Label.coerce(label)]
    end

    def default_target
      @targets[label]
    end

    private

    def add_target(target)
      unless target.label.project_path == label.project_path
        raise InvalidProjectError, "target #{target.label} does not belong to project #{label} (path scope #{path_scope.inspect})"
      end

      if @targets.key?(target.label)
        raise InvalidProjectError, "duplicate target label #{target.label} in project #{label}"
      end

      @targets[target.label] = target
    end
  end
end
