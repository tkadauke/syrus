module Permissions
  # The enforcement point for processes started through +Execution::Router+.
  #
  # Called with the request and the location of the backend that will run it
  # (+:host+ for the worker, +:container+ for a confined backend). It evaluates
  # the owner's durable rules and the confinement ceilings through
  # +ExecutionAuthorization+ and returns the result.
  #
  # The router requires an explicit +allow+. A +deny+ and an +ask+ both stop the
  # process before it starts; unlike an MCP invocation, a raw process has no
  # exact-invocation replay boundary from which approval could safely resume.
  # Provider-native actions happen inside the provider CLI and are not seen
  # here.
  class ExecutionGate
    def initialize(ceiling: ExecutionCeiling.default, logger: Rails.logger)
      @ceiling = ceiling
      @logger = logger
    end

    # Kinds whose command a model or an operator wrote, and which therefore
    # have intent worth evaluating. Everything else Execution::Router starts
    # is harness code: the command is argv the harness composed from values
    # it chose, run as deterministic plumbing with nobody to ask and nothing
    # to decide.
    #
    # Over a week of production that distinction is about 825,000 executions
    # to 3. Gating the harness with a policy meant for agents stopped the
    # harness with itself -- `git push` read as an external write blocked
    # branches from publishing, `git checkout --detach` read as destructive
    # blocked every distributed grader -- and each surfaced as its own
    # outage because an allowlist of harness kinds only grows one at a time.
    #
    # `agent` stays gated even though the harness composes its argv too: it
    # is the process that runs the model, and the FailClosedHost ceiling that
    # forces it into a container is applied through this path.
    #
    # spec/architecture/execution_kind_authorship_spec.rb requires every
    # SpawnedProcess::KIND to be declared on one side of this line, so a new
    # kind cannot default into either posture unnoticed.
    GATED_KINDS = %w[ agent chat_shell_command ].freeze

    def call(request, location: :host)
      return if unattributed?(request)
      return unless gated?(request)

      subject = ExecutionActions.subject_for_request(request, location:)
      result = ExecutionAuthorization.authorize(subject:, owner: owner_for(request), role: role_for(request), rules: rules_for(request), ceiling: @ceiling,
        context: lifecycle_context_for(request), selector_contexts: selector_contexts_for(request))
      @logger.info("[permissions] execution requires approval: #{ExecutionActions.descriptor_for(location).redact(ExecutionActions.arguments_for(subject)).to_json}") if result.ask?
      result
    end

    private

    # A tracked execution carries a +kind+ (agent, grader, git, prepare) and an
    # actor to attribute it to. One with neither is the application running its
    # own tooling: asset precompilation shelling out to brotli during
    # `docker build`, a rake task probing whether a binary is on PATH. There is
    # no owner whose rules could allow it and nobody to ask, so the gate holds
    # no opinion rather than failing closed on work that was never an agent's
    # to request. Without this, `assets:precompile` raised NotAuthorized and no
    # image could be built at all.
    #
    # Both conditions are required. An agent path that omitted +kind+ still
    # carries a run, workflow, job or chat session, and stays gated. Anything
    # able to construct an Execution::Request directly is already running
    # arbitrary code in the app process, so this is not a bypass worth
    # defending against here.
    # A missing kind keeps the stricter reading: an execution that has not
    # declared itself harness plumbing is not assumed to be any.
    def gated?(request) = request.kind.blank? || GATED_KINDS.include?(request.kind.to_s)

    def unattributed?(request)
      request.kind.blank? && request.run.nil? && request.workflow.nil? &&
        request.job.nil? && request.chat_session.nil?
    end

    def role_for(request)
      candidate = request.agent.to_s
      return candidate if AgentRole::ALL_ROLES.include?(candidate)

      request.chat_session ? AgentRole::CHAT_CODING : AgentRole::WORKFLOW_MANUAL
    end

    # Every way a persisted rule can address this process: the unscoped
    # eligible-roles selector, the chat or workflow role selectors, the
    # repository-scoped role, and the named agent.
    def selector_contexts_for(request)
      role = role_for(request)
      repository_id = request.job&.repository_id
      contexts = [ { subject_selector_type: "eligible_roles" } ]
      PermissionRule::SUBJECT_SELECTORS.each do |type, definition|
        contexts << { subject_selector_type: type } if definition[:role] == role
      end
      contexts << { subject_selector_type: "workflow_role", subject_selector_id: role }
      contexts << { subject_selector_type: "repository_role", subject_selector_id: role, subject_repository_id: repository_id } if repository_id
      agent_id = request.agent.respond_to?(:id) ? request.agent.id : request.agent
      contexts << { subject_selector_type: "agent", subject_selector_id: agent_id.to_s } if agent_id.present?
      contexts
    end

    def rules_for(request)
      user = owner_for(request)
      return [] unless user

      Management.new(user).rules.map(&:to_policy_rule)
    rescue ActiveRecord::ActiveRecordError => error
      @logger.warn("[permissions] execution rules unavailable, evaluating ceilings only: #{error.class}")
      []
    end

    def owner_for(request) = request.chat_session&.user || request.job&.user

    def lifecycle_context_for(request)
      { chat_session_id: request.chat_session&.id, job_id: request.job&.id,
        workflow_id: request.workflow&.id, run_id: request.run&.id }.compact
    end
  end
end
