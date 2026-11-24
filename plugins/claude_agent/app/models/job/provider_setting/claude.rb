class Job::ProviderSetting::Claude < Syrus::Host::JobRecord::ProviderSetting::Base
  def resolve(_job) = "claude"
end
