module ChatSessionRehydrator
  @registry = {}
  @mutex = Mutex.new

  def self.register(provider, klass)
    key = provider.to_s
    return if key.blank?

    @mutex.synchronize { @registry[key] = klass }
  end

  def self.for(provider)
    @mutex.synchronize { @registry[provider.to_s] }
  end
end
