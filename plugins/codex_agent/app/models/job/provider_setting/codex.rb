class Job::ProviderSetting::Codex < Syrus::Host::JobRecord::ProviderSetting::Base
  def resolve(_job) = "codex"
end
