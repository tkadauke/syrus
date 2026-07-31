class Job::ProviderSetting::Base
  REGISTRY = {
    "default" => "Job::ProviderSetting::Default",
    "claude" => "Job::ProviderSetting::Claude",
    "codex" => "Job::ProviderSetting::Codex"
  }.freeze

  def self.values = REGISTRY.keys

  def self.for(value)
    REGISTRY.fetch(value.to_s).constantize.new
  rescue KeyError
    raise ArgumentError, "unknown job provider setting: #{value.inspect}"
  end

  def resolve(_job)
    raise NotImplementedError
  end
end
