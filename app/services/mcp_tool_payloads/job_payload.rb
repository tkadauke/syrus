module McpToolPayloads
  # Shared job payload builders used by chat MCP read tools and future insight jobs.
  # Extend this module into a class's singleton to get all helpers as class methods.
  module JobPayload
    # Full job detail payload for read_job — includes dependencies and split PR numbers.
    def job_detail_payload(job, deployment_stages_plan: nil)
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
        agent_provider: job.workflow_agent_provider,
        job_provider_setting: job.job_provider_setting,
        priority: job.priority,
        issue_title: job.issue_title,
        scheduled_task_id: job.scheduled_task_id,
        landed_sha: job.landed_sha,
        commits_behind_base: job.commits_behind_base,
        dependencies: job.dependencies.order(:id).filter_map { |dep| dependency_payload(dep) },
        created_at: job.created_at&.iso8601,
        updated_at: job.updated_at&.iso8601
      }.merge(deployment_stages_payload(job, plan: deployment_stages_plan))
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
        agent_provider: job.workflow_agent_provider,
        job_provider_setting: job.job_provider_setting,
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

    # Serialises one JobDependency.
    def dependency_payload(dependency)
      if dependency.pending?
        {
          pending: true,
          unresolved_ref: dependency.unresolved_slug,
          unresolved_ref_kind: dependency.pending_reference_kind,
          unresolved_ref_state: dependency.pending_reference_state,
          source: dependency.source
        }
      elsif dependency.depends_on_job
        job_reference_payload(dependency.depends_on_job)
      elsif dependency.depends_on_epic
        epic_reference_payload(dependency.depends_on_epic)
      end
    end

    # Cross-epic reference included in dependency lists.
    def epic_reference_payload(epic)
      {
        epic_id: epic.id,
        display_number: epic.display_number,
        title: epic.title,
        state: epic.state
      }
    end

    def deployment_stages_payload(job, plan: nil)
      return {} unless job.landed_sha.present?

      stages = App::DeploymentStagesPayload.for_job(job, plan: plan)
      stages ? { deployment_stages: stages } : {}
    end
  end
end
