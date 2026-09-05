# An executable/dependency graph node inside a TargetGraph project.
#
# A grader is not a separate internal primitive — it's a Target with
# `kind: "grader"`. Formatters, builders, generators, and prepare actions
# are Target nodes too. See DOC-20 "Core Model".
class TargetGraph
  class Target
    KINDS = %w[default library binary application formatter builder grader prepare generator repo_check].freeze

    InvalidTargetError = Class.new(StandardError)

    attr_reader :label, :kind, :source_paths, :command, :dependencies,
                :phases, :timeout_minutes, :owner_config_path

    def initialize(label:, kind: "default", source_paths: [], command: nil, dependencies: [],
                   phases: [], required: false, timeout_minutes: nil, owner_config_path: nil)
      @label = Label.coerce(label)
      @kind = kind.to_s
      unless KINDS.include?(@kind)
        raise InvalidTargetError, "unknown target kind #{@kind.inspect} for #{@label} (expected one of #{KINDS.join(', ')})"
      end

      @source_paths = Array(source_paths).map(&:to_s).map(&:strip).reject(&:empty?).freeze
      @command = command.to_s.strip.presence
      @dependencies = Array(dependencies).map { |dep| Label.coerce(dep) }.freeze
      @phases = Array(phases).map(&:to_s).map(&:strip).reject(&:empty?).freeze
      @required = ActiveModel::Type::Boolean.new.cast(required) || false
      @timeout_minutes = timeout_minutes.nil? ? nil : Integer(timeout_minutes)
      @owner_config_path = owner_config_path.to_s.strip.presence
      freeze
    end

    KINDS.each do |k|
      define_method(:"#{k}?") { kind == k }
    end

    def required?
      @required
    end

    def depends_on?(other_label)
      dependencies.include?(Label.coerce(other_label))
    end
  end
end
