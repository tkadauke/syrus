module Permissions
  # The enforcement point for processes started through +Execution::Router+.
  #
  # Called with the request and the location of the backend that will run it
  # (+:host+ for the worker, +:container+ for a confined backend). It evaluates
  # the owner's durable rules and the confinement ceilings through
  # +ExecutionAuthorization+ and returns the result.
  #
  # Enforcement today is deny-only. A +deny+ (an explicit rule, or a ceiling)
  # stops the process before it starts. An +ask+ is recorded in the log with the
  # redacted subject but does not block: Syrus-launched processes are not
  # interactive, and an approval route for them does not exist yet. Provider-
  # native actions happen inside the provider CLI and are not seen here.
  class ExecutionGate
    def initialize(ceiling: ExecutionCeiling.default, logger: Rails.logger)
      @ceiling = ceiling
      @logger = logger
    end

    def call(request, location: :host)
      subject = ExecutionActions.subject_for_request(request, location:)
      result = ExecutionAuthorization.authorize(subject:, role: role_for(request), rules: rules_for(request), ceiling: @ceiling)
      if result.ask?
        @logger.info("[permissions] execution would ask: #{ExecutionActions.descriptor_for(location).redact(ExecutionActions.arguments_for(subject)).to_json}")
      end
      result
    end

    private

    def role_for(request)
      candidate = request.agent.to_s
      return candidate if AgentRole::ALL_ROLES.include?(candidate)

      request.chat_session ? AgentRole::CHAT_CODING : AgentRole::WORKFLOW_MANUAL
    end

    def rules_for(request)
      user = request.chat_session&.user || request.job&.user
      return [] unless user

      Management.new(user).policy_rules
    rescue ActiveRecord::ActiveRecordError => error
      @logger.warn("[permissions] execution rules unavailable, evaluating ceilings only: #{error.class}")
      []
    end
  end
end
