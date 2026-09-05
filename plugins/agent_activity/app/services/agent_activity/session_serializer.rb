module AgentActivity
  # One row per agentic Run ("session"). Role/label come structurally from
  # Step::Kind + AgentRole -- never inferred from transcript text.
  class SessionSerializer
    def self.call(run, transcript_path:)
      new(run, transcript_path: transcript_path).call
    end

    def initialize(run, transcript_path:)
      @run = run
      @transcript_path = transcript_path
    end

    def call
      outcome = OutcomeSummary.for(@run)
      job = @run.job
      repository = job&.repository

      {
        id: @run.id,
        slug: @run.slug,
        state: @run.state,
        step_kind: step.kind,
        role: AgentRole.for_step_kind(step.kind),
        role_label: Step::Kind.label_for(step.kind),
        agent_provider: @run.agent_provider,
        agent_outcome: @run.agent_outcome,
        outcome_summary: outcome[:text],
        outcome_verdict: outcome[:verdict],
        started_at: @run.started_at&.iso8601,
        finished_at: @run.finished_at&.iso8601,
        created_at: @run.created_at&.iso8601,
        duration_seconds: duration_seconds,
        transcript_path: @transcript_path,
        job: job_payload(job),
        repository: repository_payload(repository),
        workflow_id: step.workflow_id,
        trigger_kind: step.workflow&.trigger_kind
      }
    end

    private

    def step
      @run.step
    end

    def duration_seconds
      return nil unless @run.started_at

      finish = @run.finished_at || Time.current
      (finish - @run.started_at).round
    end

    def job_payload(job)
      return nil unless job

      {
        id: job.id,
        slug: ::App::Presentation.job_slug(job.id),
        title: job.issue_title,
        state: job.state
      }
    end

    def repository_payload(repository)
      return nil unless repository

      {
        id: repository.id,
        slug: "#{repository.owner}/#{repository.name}"
      }
    end
  end
end
