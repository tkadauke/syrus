module Permissions
  # Decides whether a Local Mode +run_command+ / +write_file+ call may be
  # dispatched to the daemon, and records the authority an operator's
  # confirmation grants.
  #
  # The decision goes through the common evaluator and lease authorizer, so
  # permanent rules, denies, and revoked or expired leases all apply the same
  # way they do elsewhere. Without an applicable rule or lease the descriptor
  # default (+ask+) leaves the call waiting on an operator confirmation, which
  # keeps its existing pending-action lifecycle.
  class LocalModeAuthorization
    Result = Data.define(:decision, :lease) do
      def allowed? = decision.allow?
      def denied? = decision.deny?
    end

    def self.authorize(...) = new(...).authorize
    def self.grant_after_confirmation(chat_session:, tool_name:, arguments:, **options)
      new(chat_session:, tool_name:, arguments:).grant_after_confirmation(**options)
    end

    def initialize(chat_session:, tool_name:, arguments:)
      @chat_session = chat_session
      @tool_name = tool_name.to_s
      @arguments = arguments.to_h
    end

    def authorize
      result = Management.new(chat_session.user).authorize(
        descriptor:, role: AgentRole::CHAT_LOCAL, resource_scope:, arguments:, context:
      )
      Result.new(decision: result.decision, lease: result.lease)
    end

    # Called once a confirmed call has run. A plain call is covered for the rest
    # of this Chat Session for exactly the same normalized command or path and
    # content; anything with network, credential, destructive, or privilege
    # effects stays exact-invocation only and creates no lease. Returns the
    # lease, or nil when the confirmation only covered the one invocation.
    def grant_after_confirmation(source: nil, duration: :chat_session)
      return unless duration.to_sym == :chat_session
      return unless LocalModeActions.session_eligible?(tool_name, arguments)

      AuthorityGrant.issue!(
        duration: :chat_session, descriptor:, owner: chat_session.user, actor: chat_session.user,
        subject_selector_type: "local_chat", role: AgentRole::CHAT_LOCAL, resource_scope:,
        arguments:, context:, constraints: descriptor.normalize_fingerprint(arguments),
        source:, chat_session:, rules: Management.new(chat_session.user).rules.map(&:to_policy_rule)
      )
    end

    private

    attr_reader :chat_session, :tool_name, :arguments

    def descriptor = @descriptor ||= LocalModeActions.descriptor_for(tool_name)

    def resource_scope = LocalModeActions.resource_scope_for(chat_session)

    def context
      { chat_session_id: chat_session.id, subject_selector_type: "local_chat", user_id: chat_session.user_id }
    end
  end
end
