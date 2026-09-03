module ChatSessionRehydrator
  @registry = {}
  @mutex = Mutex.new

  # Returns the teardown that removes this provider again (see
  # Syrus::Installer); a no-op proc for a blank key so callers can treat the
  # return value uniformly.
  def self.register(provider, klass)
    key = provider.to_s
    return -> {} if key.blank?

    @mutex.synchronize do
      previous = @registry[key]
      @registry[key] = klass
      -> { @mutex.synchronize { previous ? @registry[key] = previous : @registry.delete(key) } }
    end
  end

  def self.for(provider)
    Syrus::Installer.sync!
    @mutex.synchronize { @registry[provider.to_s] }
  end
end
