module Mcp::Tools::ChatDiscoveryPayload
  MAX_ATTACHED_JOBS = 5

  def chat_discovery_payload(session)
    repository = session.repository
    attached_jobs = session.attached_jobs.to_a

    {
      mode: session.mode.presence || "planning",
      repository: repository&.slug,
      attached_jobs_count: attached_jobs.size,
      attached_jobs: attached_jobs.first(MAX_ATTACHED_JOBS).map { |job| attached_job_payload(job) }
    }
  end

  def attached_job_payload(job)
    {
      id: job.id,
      slug: job.slug,
      title: job.issue_title.presence || job.title,
      state: job.state,
      repository: job.repository&.slug
    }
  end
end
