module AgentActivity
  # One row per Agent. Role/label come from the resumable's structural context:
  # Step::Kind for workflow Runs, ChatSession#mode for chats, and the
  # design-doc/thread pair for design-doc agents.
  class SessionSerializer
    def self.call(agent, transcript_path: nil, scope: :mine)
      new(agent, transcript_path: transcript_path, scope: scope).call
    end

    def initialize(agent, transcript_path: nil, scope: :mine)
      @agent = agent
      @transcript_path = transcript_path
      @scope = scope
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
        transcript_path: @transcript_path || @context.transcript_path(scope: @scope),
        chat_path: @context.chat_path,
        job: @context.job_payload,
        repository: @context.repository_payload,
        workflow_id: @context.workflow_id,
        trigger_kind: @context.trigger_kind
      }
    end

    private

    def latest_process
      @latest_process ||= if @agent.association(:spawned_processes).loaded?
        @agent.spawned_processes
          .select { |process| process.kind == "agent" }
          .max_by { |process| [ process.started_at || Time.at(0), process.id || 0 ] }
      else
        @agent.spawned_processes
          .where(kind: "agent")
          .order(started_at: :desc, id: :desc)
          .first
      end
    end

    def running_process?
      @running_process ||= if @agent.association(:spawned_processes).loaded?
        @agent.spawned_processes.any? { |process| process.kind == "agent" && process.finished_at.nil? }
      else
        @agent.spawned_processes.where(kind: "agent", finished_at: nil).exists?
      end
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

end
