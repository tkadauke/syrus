class Job::ProviderSetting::Claude < Job::ProviderSetting::Base
  def resolve(_job) = "claude"
end
