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
    @landing_workflow_kinds ||= definitions_matching { |definition| definition.landing_lock? && definition.first_class? }
      .map(&:workflow_trigger_kind)
      .uniq
      .freeze
  end

  def landing_work_unit_kinds
    @landing_work_unit_kinds ||= kinds_matching { |definition| definition.landing_lock? && definition.first_class? }
  end

  def epic_wide_kinds
    @epic_wide_kinds ||= kinds_matching { |definition| definition.scope == "epic" && definition.first_class? }
  end

  def ci_failure_blocking_kinds
    @ci_failure_blocking_kinds ||= kinds_matching(&:blocks_ci_failure?)
  end

  def active_repair_work_kinds
    @active_repair_work_kinds ||= kinds_matching(&:active_repair_work?)
  end

  def retry_workflow_attempt_kinds
    @retry_workflow_attempt_kinds ||= kinds_matching(&:retry_workflow_attempt?)
  end

  def landing_validation_prefetch_source_kinds
    @landing_validation_prefetch_source_kinds ||= kinds_matching(&:landing_validation_prefetch_source?)
  end

  def landing_validation_child_kinds
    @landing_validation_child_kinds ||= kinds_matching(&:landing_validation_child?)
  end

  def agent_concurrency_exempt_kinds
    @agent_concurrency_exempt_kinds ||= kinds_matching(&:agent_concurrency_exempt?)
  end

  def child_kinds_for(parent_kind)
    load_definitions
    registry.values
      .map(&:new)
      .select { |definition| definition.parent_kind == parent_kind.to_s }
      .map(&:kind)
      .freeze
  end

  def family_kinds_for(kind)
    [ kind.to_s, *child_kinds_for(kind) ].uniq.freeze
  end

  def landing_validation_child_kind_for(parent_kind)
    load_definitions
    registry.values
      .map(&:new)
      .find { |definition| definition.parent_kind == parent_kind.to_s && definition.landing_validation_child? }
      &.kind
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
      @landing_work_unit_kinds
      @epic_wide_kinds
      @ci_failure_blocking_kinds
      @active_repair_work_kinds
      @retry_workflow_attempt_kinds
      @landing_validation_prefetch_source_kinds
      @landing_validation_child_kinds
      @agent_concurrency_exempt_kinds
    ].each do |ivar|
      remove_instance_variable(ivar) if instance_variable_defined?(ivar)
    end
  end

  def load_definitions
    require_dependency "work_definitions/base"
    require_dependency "work_definitions/built_ins"
    require_dependency "work_definitions/registry_validator"
  end

  def validate_registry!
    errors = WorkDefinitions::RegistryValidator.call
    return true if errors.empty?

    raise Error, errors.map(&:message).join("; ")
  end

  def kinds_matching(&predicate)
    definitions_matching(&predicate)
      .map(&:kind)
      .freeze
  end

  def definitions_matching(&predicate)
    registry.values
      .map(&:new)
      .select(&predicate)
  end
end
