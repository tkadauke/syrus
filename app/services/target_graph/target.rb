class TargetGraph
  # An execution graph node: a grader, formatter, builder, generator,
  # prepare action, repo check, or plain library/binary/application node.
  # See DOC-20 "Core Model" and "Dependency Edges".
  Target = Data.define(
    :label, :kind, :project_id, :source_scope, :command, :dependencies,
    :phases, :required, :timeout_minutes, :owner_config_path
  ) do
    KINDS = %w[default library binary application formatter builder grader prepare generator repo_check].freeze
    # Mirrors SyrusYml::GRADE_PHASES's vocabulary, but this graph model does
    # not depend on SyrusYml -- it is meant to stand on its own so a future
    # compiler (not part of this slice) can populate it from legacy config.
    PHASES = %w[review landing ci promotion].freeze

    def initialize(
      label:, kind:, project_id:,
      source_scope: [], command: nil, dependencies: [], phases: [],
      required: false, timeout_minutes: nil, owner_config_path: nil
    )
      raise ArgumentError, "label must be a TargetGraph::Label" unless label.is_a?(TargetGraph::Label)
      raise ArgumentError, "kind #{kind.inspect} must be one of #{KINDS.join(', ')}" unless KINDS.include?(kind.to_s)

      dependencies = Array(dependencies)
      unless dependencies.all? { |dependency| dependency.is_a?(TargetGraph::Label) }
        raise ArgumentError, "dependencies must all be TargetGraph::Label instances"
      end

      phases = Array(phases).map(&:to_s)
      invalid_phases = phases - PHASES
      raise ArgumentError, "phases #{invalid_phases.join(', ')} must be one of #{PHASES.join(', ')}" if invalid_phases.any?

      if !timeout_minutes.nil? && !(timeout_minutes.is_a?(Integer) && timeout_minutes.positive?)
        raise ArgumentError, "timeout_minutes must be a positive integer"
      end

      project_id = project_id.to_s.strip
      raise ArgumentError, "project_id must not be blank" if project_id.empty?

      super(
        label: label,
        kind: kind.to_s,
        project_id: project_id,
        source_scope: Array(source_scope).map(&:to_s),
        command: command&.to_s&.strip&.presence,
        dependencies: dependencies,
        phases: phases,
        required: !!required,
        timeout_minutes: timeout_minutes,
        owner_config_path: owner_config_path&.to_s
      )
    end

    # Executable nodes (graders, formatters, builders, generators, prepare
    # actions) carry a shell command; pure dependency nodes (`default`,
    # `library`, `binary`, `application`) typically do not.
    def executable?
      !command.nil?
    end

    def depends_on?(other_label)
      dependencies.include?(other_label)
    end
  end
end
