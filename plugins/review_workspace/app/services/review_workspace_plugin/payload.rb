module ReviewWorkspacePlugin
  class Payload
    def self.call(user:, scope: Job.all)
      jobs = EligibleJobs.call(user:, scope:)
      { count: jobs.length, jobs: jobs.map { |job| serialize(job) } }
    end

    def self.serialize(job)
      reference = job.slug.presence || "JOB-#{job.id}"
      {
        id: job.id,
        slug: reference,
        title: job.issue_title.presence || reference,
        priority: job.priority,
        ready_at: (job.finished_at || job.updated_at || job.created_at).iso8601,
        dependency_blocked: !job.dependencies_satisfied?,
        repository: { id: job.repository_id, slug: job.repository.slug },
        pr_number: job.pr_number || job.external_pr_number
      }
    end
    private_class_method :serialize
  end
end
