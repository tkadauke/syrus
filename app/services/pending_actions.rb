module PendingActions
  REGISTRY = {}

  def self.for(action_key)
    REGISTRY.fetch(action_key.to_s) { raise UnknownAction, "unknown pending action: #{action_key}" }
  end

  def self.register(klass)
    REGISTRY[klass.action_key] = klass
  end

  UnknownAction = Class.new(StandardError)
end
