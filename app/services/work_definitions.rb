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

  def registry
    load_definitions
    @registry ||= WorkDefinitions::Base.descendants.index_by(&:kind).freeze
  end

  def reset_registry!
    remove_instance_variable(:@registry) if instance_variable_defined?(:@registry)
  end

  def load_definitions
    require_dependency "work_definitions/base"
    require_dependency "work_definitions/built_ins"
  end
end
