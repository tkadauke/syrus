module PendingActions
  REGISTRY = {}

  def self.for(action_key)
    key = action_key.to_s

    return REGISTRY[key] if REGISTRY.key?(key)

    load_action_class(key)

    REGISTRY.fetch(key) { raise UnknownAction, "unknown pending action: #{action_key}" }
  end

  def self.register(klass)
    REGISTRY[klass.action_key] = klass
  end

  UnknownAction = Class.new(StandardError)

  def self.load_action_class(action_key)
    "PendingActions::#{action_key.to_s.camelize}".safe_constantize
  end
end
