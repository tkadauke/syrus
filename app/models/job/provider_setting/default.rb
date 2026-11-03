class Job::ProviderSetting::Default < Job::ProviderSetting::Base
  def resolve(job)
    effective_user = job.owner_user || job.user
    effective_user&.agent_provider
  end
end
