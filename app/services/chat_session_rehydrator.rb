module ChatSessionRehydrator
  REGISTRY = {
    "claude" => "ChatSessionRehydrator::Claude",
    "codex"  => "ChatSessionRehydrator::Codex"
  }.freeze

  def self.for(provider)
    REGISTRY[provider.to_s]&.constantize
  end
end
