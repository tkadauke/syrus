class Job::ProviderSetting::Default < Job::ProviderSetting::Base
  def resolve(job)
    effective_user = job.owner_user || job.user
    job.repository&.effective_agent_provider(user: effective_user) || effective_user&.agent_provider
  end
end
