module WorkDefinitions
  class Error < StandardError; end
  class UnknownKind < Error; end

  module_function

  def for(kind)
    kind = kind.to_s
    definition_class = registry.fetch(kind) do
      raise UnknownKind, "unknown work definition kind=#{kind.inspect}"
    end
    definition_class.new
  end

  def landing_lock_kinds
    @landing_lock_kinds ||= kinds_matching(&:landing_lock?)
  end

  def landing_workflow_kinds
    @landing_workflow_kinds ||= kinds_matching { |definition| definition.landing_lock? && definition.first_class? }
  end

  def epic_wide_kinds
    @epic_wide_kinds ||= kinds_matching { |definition| definition.scope == "epic" && definition.first_class? }
  end

  def ci_failure_blocking_kinds
    @ci_failure_blocking_kinds ||= kinds_matching(&:blocks_ci_failure?)
  end

  def registry
    load_definitions
    @registry ||= WorkDefinitions::Base.descendants.index_by(&:kind).freeze
  end

  def reset_registry!
    %i[
      @registry
      @landing_lock_kinds
      @landing_workflow_kinds
      @epic_wide_kinds
      @ci_failure_blocking_kinds
    ].each do |ivar|
      remove_instance_variable(ivar) if instance_variable_defined?(ivar)
    end
  end

  def load_definitions
    require_dependency "work_definitions/base"
    require_dependency "work_definitions/built_ins"
  end

  def kinds_matching(&predicate)
    registry.values
      .map(&:new)
      .select(&predicate)
      .map(&:kind)
      .freeze
  end
end
