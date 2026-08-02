class McpToolContext
  attr_reader :surface, :role, :user, :repository, :epic, :job, :workflow, :run, :chat_session,
              :allowed_memory_scopes, :allowed_repository_ids,
              :allowed_job_ids, :allowed_workflow_ids, :allowed_run_ids,
              :allowed_chat_session_ids, :allowed_context_sources

  def initialize(surface:, role:, user:, repository: nil, epic: nil, job: nil,
                 workflow: nil, run: nil, chat_session: nil,
                 allowed_memory_scopes: [], allowed_repository_ids: [],
                 allowed_job_ids: nil, allowed_workflow_ids: nil,
                 allowed_run_ids: nil, allowed_chat_session_ids: nil,
                 allowed_context_sources: nil)
    @surface                = surface
    @role                   = role
    @user                   = user
    @repository             = repository
    @epic                   = epic
    @job                    = job
    @workflow               = workflow
    @run                    = run
    @chat_session           = chat_session
    @allowed_memory_scopes  = Array(allowed_memory_scopes).freeze
    @allowed_repository_ids = Array(allowed_repository_ids).freeze
    @allowed_job_ids        = allowed_job_ids
    @allowed_workflow_ids   = allowed_workflow_ids
    @allowed_run_ids        = allowed_run_ids
    @allowed_chat_session_ids = allowed_chat_session_ids
    @allowed_context_sources  = allowed_context_sources
  end

  def self.from_run(run)
    new(
      surface:                :run,
      role:                   role_for_run(run),
      user:                   run.job.user,
      repository:             run.job.repository,
      job:                    run.job,
      workflow:               run.workflow,
      run:                    run,
      allowed_memory_scopes:  [ "repository" ],
      allowed_repository_ids: [ run.job.repository_id ].compact
    )
  end

  def self.from_chat_session(chat_session)
    new(
      surface:                :chat,
      role:                   role_for_chat(chat_session),
      user:                   chat_session.user,
      repository:             chat_session.repository,
      chat_session:           chat_session,
      allowed_memory_scopes:  ChatMemory::TOOL_SCOPES,
      allowed_repository_ids: chat_session.attached_repositories.ids
    )
  end

  # Build from a raw MCP server_context hash. Supports both run-sidecar
  # shape ({ run_id: }) and chat-sidecar shape ({ chat_session: }).
  def self.from_server_context(server_context)
    if server_context.key?(:chat_session)
      from_chat_session(server_context[:chat_session])
    elsif server_context.key?(:run)
      from_run(server_context[:run])
    else
      SyrusMcp.with_database_connection do
        from_run(Run.find(server_context.fetch(:run_id)))
      end
    end
  end

  def run?
    surface == :run
  end

  def chat?
    surface == :chat
  end

  private_class_method def self.role_for_run(run)
    case run.step&.kind
    when "agent_rebase", "stack_agent_rebase", "push_agent_rebase"
      AgentRole::WORKFLOW_REBASE_CONFLICT
    when "summarize", "summarize_amend", "test_plan", "refresh_job_metadata"
      AgentRole::WORKFLOW_SUMMARY_TEST_PLAN
    when "adversarial_review"
      AgentRole::WORKFLOW_ADVERSARIAL_REVIEWER
    when "agent_insight_run"
      AgentRole::AGENT_INSIGHT
    else
      reconciliation_feedback_role_for(run) || AgentRole::WORKFLOW_IMPLEMENT
    end
  end

  # Returns WORKFLOW_RECONCILIATION_FEEDBACK when the run belongs to a
  # historical standalone Epic reconciliation Job configured for feedback mode.
  # This grants submit_chat_feedback in addition to the standard implement tools.
  private_class_method def self.reconciliation_feedback_role_for(run)
    epic = run.job.epic
    return unless epic
    return unless epic.reconciliation_job_id == run.job.id
    return unless epic.resolved_reconciliation_mode == "feedback"

    AgentRole::WORKFLOW_RECONCILIATION_FEEDBACK
  end

  private_class_method def self.role_for_chat(chat_session)
    if chat_session.system_kind_supervisor?
      AgentRole::CHAT_ADMIN
    elsif chat_session.coding?
      AgentRole::CHAT_CODING
    elsif chat_session.mode == "local"
      AgentRole::CHAT_LOCAL
    else
      AgentRole::CHAT_PLANNER
    end
  end
end
