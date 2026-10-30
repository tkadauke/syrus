class McpToolContext
  attr_reader :surface, :role, :user, :repository, :epic, :job, :workflow, :run, :chat_session,
              :allowed_memory_scopes, :allowed_repository_ids,
              :allowed_job_ids, :allowed_workflow_ids, :allowed_run_ids,
              :allowed_chat_session_ids, :allowed_context_sources
  attr_reader :granted_capabilities, :capability_approval_policies, :interactive

  def initialize(surface:, role:, user:, repository: nil, epic: nil, job: nil,
                 workflow: nil, run: nil, chat_session: nil,
                 allowed_memory_scopes: [], allowed_repository_ids: [],
                 allowed_job_ids: nil, allowed_workflow_ids: nil,
                 allowed_run_ids: nil, allowed_chat_session_ids: nil,
                 allowed_context_sources: nil, granted_capabilities: [], capability_approval_policies: {}, interactive: false)
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
    @granted_capabilities     = Array(granted_capabilities).map(&:to_s).freeze
    @capability_approval_policies = capability_approval_policies.stringify_keys.freeze
    @interactive              = interactive
  end

  def self.from_run(run)
    role = role_for_run(run)
    contributed = run_context_attributes(run, role)
    new(
      surface:                :run,
      role:                   role,
      user:                   run.job.user,
      repository:             run.job.repository,
      job:                    run.job,
      workflow:               run.workflow,
      run:                    run,
      allowed_memory_scopes:  [ "repository" ],
      allowed_repository_ids: [ run.job.repository_id ].compact,
      interactive: false,
      **contributed
    )
  end

  def self.from_chat_session(chat_session, evaluator: false)
    coworker = coworker_for_chat(chat_session)
    new(
      surface:                :chat,
      role:                   evaluator ? AgentRole::CHAT_EVALUATOR : role_for_chat(chat_session),
      user:                   chat_session.user,
      repository:             chat_session.repository,
      chat_session:           chat_session,
      # What this surface permits, not what the memory store defines: a chat
      # may write cross-repository facts, a workflow run may not.
      allowed_memory_scopes:  coworker ? %w[ global repository instance ] : %w[ global repository ],
      allowed_repository_ids: chat_session.attached_repositories.ids,
      allowed_chat_session_ids: coworker ? coworker.readable_chat_session_ids : nil,
      granted_capabilities: coworker ? coworker.grants.pluck(:capability) : [],
      capability_approval_policies: coworker ? coworker.grants.pluck(:capability, :approval_policy).to_h : {},
      interactive: interactive_turn?(chat_session)
    )
  end

  def self.for_macos_worker_update
    new(
      surface: :macos_worker,
      role: "macos_worker_update",
      user: nil
    )
  end

  # Build from a raw MCP server_context hash. Supports both run-sidecar
  # shape ({ run_id: }) and chat-sidecar shape ({ chat_session: }).
  def self.from_server_context(server_context)
    if server_context.key?(:run)
      from_run(server_context[:run])
    elsif server_context.key?(:chat_session)
      from_chat_session(server_context[:chat_session], evaluator: server_context[:evaluator] == true)
    else
      Mcp::Tools.with_database_connection do
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

  def macos_worker?
    surface == :macos_worker
  end

  private_class_method def self.role_for_run(run)
    AgentRole.for_step_kind(run.step&.kind)
  end

  private_class_method def self.role_for_chat(chat_session)
    if coworker_for_chat(chat_session)
      AgentRole::COWORKER_CHAT
    elsif chat_session.coding?
      AgentRole::CHAT_CODING
    elsif chat_session.mode == "local"
      AgentRole::CHAT_LOCAL
    else
      AgentRole::CHAT_PLANNER
    end
  end

  private_class_method def self.coworker_for_chat(chat_session)
    return unless chat_session.respond_to?(:coworker)

    coworker = chat_session.coworker
    coworker if coworker.respond_to?(:kind) && coworker.kind == "coworker"
  end

  private_class_method def self.run_context_attributes(run, role)
    Syrus::PluginRegistry.providers_for(:mcp_run_context_contributor).each_with_object({}) do |provider, attributes|
      contributed = provider.context_attributes(run: run, role: role).to_h.symbolize_keys
      duplicate = attributes.keys & contributed.keys
      raise ArgumentError, "duplicate MCP run context attributes: #{duplicate.join(', ')}" if duplicate.any?

      attributes.merge!(contributed)
    end
  end

  private_class_method def self.interactive_turn?(chat_session)
    return false unless chat_session.respond_to?(:current_turn_message_id)

    message_id = chat_session.current_turn_message_id
    message_id.present? && chat_session.messages.where(id: message_id, role: "user").exists?
  end
end
