module AgentActivity
  class RunSessionContext < SessionContext
    def kind = step&.kind

    def role
      AgentRole.for_step_kind(step.kind) if step
    end

    def role_label = step ? Step::Kind.label_for(step.kind) : "Workflow"
    def agent_provider = @resumable.agent_provider
    def state = @resumable.state
    def workflow_id = step&.workflow_id
    def trigger_kind = step&.workflow&.trigger_kind

    def transcript_path(scope:)
      if scope == :admin
        "/api/v1/app/admin/agent_activity/sessions/#{@resumable.id}/artifacts"
      else
        "/api/v1/app/jobs/#{@resumable.job_id}/runs/#{@resumable.id}/artifacts"
      end
    end

    def outcome_summary
      OutcomeSummary.for(@resumable)[:text]
    end

    def outcome_verdict
      OutcomeSummary.for(@resumable)[:verdict]
    end

    def job_payload
      return nil unless job

      {
        id: job.id,
        slug: ::App::Presentation.job_slug(job.id),
        title: job.issue_title,
        state: job.state
      }
    end

    def repository_payload
      return nil unless repository

      {
        id: repository.id,
        slug: "#{repository.owner}/#{repository.name}"
      }
    end

    private

    def step
      @step ||= @resumable.step
    end

    def job
      @job ||= @resumable.job
    end

    def repository
      @repository ||= job&.repository
    end
  end
end
