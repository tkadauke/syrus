module McpToolPayloads
  # Shared job payload builders used by chat MCP read tools and future insight jobs.
  # Extend this module into a class's singleton to get all helpers as class methods.
  module JobPayload
    # Full job detail payload for read_job — includes dependencies and split PR numbers.
    def job_detail_payload(job)
      {
        id: job.id,
        kind: job.kind,
        issue_number: job.issue_number,
        pr_number: job.pr_number || job.external_pr_number,
        internal_pr_number: job.pr_number,
        external_pr_number: job.external_pr_number,
        branch_name: job.branch_name,
        state: job.state,
        closure_reason: job.closure_reason,
        agent_provider: job.agent_provider,
        priority: job.priority,
        issue_title: job.issue_title,
        scheduled_task_id: job.scheduled_task_id,
        dependencies: job.dependencies.order(:id).filter_map { |dep| dependency_payload(dep) },
        created_at: job.created_at&.iso8601,
        updated_at: job.updated_at&.iso8601
      }
    end

    # Compact payload for list_jobs — includes repository_slug but not dependencies.
    def job_list_payload(job)
      {
        id: job.id,
        repository_slug: job.repository&.slug,
        kind: job.kind,
        issue_number: job.issue_number,
        pr_number: job.pr_number || job.external_pr_number,
        branch_name: job.branch_name,
        state: job.state,
        closure_reason: job.closure_reason,
        agent_provider: job.agent_provider,
        priority: job.priority,
        issue_title: job.issue_title,
        created_at: job.created_at&.iso8601,
        updated_at: job.updated_at&.iso8601
      }
    end

    # Minimal payload for search_jobs results — title-focused.
    def job_search_payload(job)
      {
        id: job.id,
        repository_slug: job.repository&.slug,
        kind: job.kind,
        issue_title: job.issue_title,
        state: job.state,
        pr_number: job.pr_number || job.external_pr_number,
        priority: job.priority,
        created_at: job.created_at&.iso8601,
        updated_at: job.updated_at&.iso8601
      }
    end

    # Cross-job reference included in dependency lists.
    def job_reference_payload(job)
      {
        id: job.id,
        issue_number: job.issue_number,
        issue_title: job.issue_title,
        state: job.state,
        repository: job.repository.slug
      }
    end

    # Serialises one JobDependency. Returns nil for unresolvable epic dependencies.
    def dependency_payload(dependency)
      if dependency.pending?
        {
          pending: true,
          unresolved_ref: dependency.unresolved_slug,
          source: dependency.source
        }
      elsif dependency.depends_on_job
        job_reference_payload(dependency.depends_on_job)
      end
    end
  end
end
