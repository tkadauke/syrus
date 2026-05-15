module Workflows
  SKIP_PREPARE_LABEL = "syrus-skip-prepare".freeze

  def self.label_names(labels)
    Array(labels).map do |label|
      if label.respond_to?(:name)
        label.name
      elsif label.is_a?(Hash)
        label[:name] || label["name"] || label.to_s
      else
        label.to_s
      end
    end
  end

  REGISTRY = Workflow::TriggerKind.registry

  def self.for(trigger_kind:)
    Workflow::TriggerKind.template_for(trigger_kind)
  rescue ArgumentError
    raise ArgumentError, "no workflow template for trigger_kind=#{trigger_kind.inspect}"
  end
end
