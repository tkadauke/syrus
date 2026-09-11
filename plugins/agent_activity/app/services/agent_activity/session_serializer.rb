module AgentActivity
  # One row per Agent. Role/label come from the resumable's structural context:
  # Step::Kind for workflow Runs, ChatSession#mode for chats, and the
  # design-doc/thread pair for design-doc agents.
  class SessionSerializer
    def self.call(agent, transcript_path: nil)
      new(agent, transcript_path: transcript_path).call
    end

    def initialize(agent, transcript_path: nil)
      @agent = agent
      @transcript_path = transcript_path
      @context = SessionContext.for(agent)
    end

    def call
      {
        id: @agent.id,
        slug: "AGENT-#{@agent.id}",
        state: state,
        step_kind: @context.kind,
        role: @context.role,
        role_label: @context.role_label,
        agent_provider: @context.agent_provider,
        agent_outcome: latest_process&.outcome,
        outcome_summary: @context.outcome_summary,
        outcome_verdict: @context.outcome_verdict,
        started_at: latest_process&.started_at&.iso8601,
        finished_at: latest_process&.finished_at&.iso8601,
        created_at: @agent.created_at&.iso8601,
        duration_seconds: duration_seconds,
        transcript_path: @transcript_path,
        job: @context.job_payload,
        repository: @context.repository_payload,
        workflow_id: @context.workflow_id,
        trigger_kind: @context.trigger_kind
      }
    end

    private

    def latest_process
      @latest_process ||= @agent.spawned_processes
        .where(kind: "agent")
        .order(started_at: :desc, id: :desc)
        .first
    end

    def running_process?
      @running_process ||= @agent.spawned_processes.where(kind: "agent", finished_at: nil).exists?
    end

    def state
      return "running" if running_process?

      @context.state.presence || latest_process&.outcome || "succeeded"
    end

    def duration_seconds
      return nil unless latest_process&.started_at

      finish = latest_process.finished_at || Time.current
      (finish - latest_process.started_at).round
    end
  end

  class SessionContext
    REGISTRY = {
      "Run" => "AgentActivity::RunSessionContext",
      "ChatSession" => "AgentActivity::ChatSessionContext",
      "DesignDocs::DesignDocAgentRun" => "AgentActivity::DesignDocSessionContext"
    }.freeze

    def self.for(agent)
      class_name = REGISTRY.fetch(agent.resumable_type, "AgentActivity::UnknownSessionContext")
      class_name.constantize.new(agent.resumable)
    end

    def initialize(resumable)
      @resumable = resumable
    end

    def kind = nil
    def role = nil
    def role_label = "Agent"
    def agent_provider = nil
    def state = nil
    def outcome_summary = nil
    def outcome_verdict = nil
    def job_payload = nil
    def repository_payload = nil
    def workflow_id = nil
    def trigger_kind = nil
  end

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

  class ChatSessionContext < SessionContext
    ROLE_BY_MODE = {
      "planning" => AgentRole::CHAT_PLANNER,
      "coding" => AgentRole::CHAT_CODING,
      "local" => AgentRole::CHAT_LOCAL
    }.freeze

    def kind = @resumable.mode || "chat"
    def role = ROLE_BY_MODE.fetch(@resumable.mode, AgentRole::CHAT_PLANNER)
    def role_label = @resumable.mode&.humanize || "Chat"
    def agent_provider = @resumable.chat_provider

    def repository_payload
      repository = @resumable.repository
      return nil unless repository

      {
        id: repository.id,
        slug: "#{repository.owner}/#{repository.name}"
      }
    end
  end

  class DesignDocSessionContext < SessionContext
    def kind = "design_doc"
    def role = AgentRole::CHAT_PLANNER
    def role_label = "Design Doc"
    def agent_provider = @resumable.agent_provider
    def state = @resumable.status == "canceled" ? "cancelled" : @resumable.status

    def outcome_summary
      "#{design_doc.display_id} #{design_doc.title}"
    end

    def repository_payload
      repository = design_doc.repositories.first
      return nil unless repository

      {
        id: repository.id,
        slug: "#{repository.owner}/#{repository.name}"
      }
    end

    private

    def design_doc
      @design_doc ||= @resumable.design_doc
    end
  end

  class UnknownSessionContext < SessionContext
    def role_label = @resumable.class.name.demodulize.underscore.humanize
  end
end
