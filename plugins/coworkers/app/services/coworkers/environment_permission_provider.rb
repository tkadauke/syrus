module Coworkers
  class EnvironmentPermissionProvider
    include Syrus::Plugin::PermissionProvider

    CAPABILITY = "syrus.coworker_environment@v1".freeze
    OPERATIONS = {
      request_build: "syrus.coworker_environment/request_build@v1",
      publish: "syrus.coworker_environment/publish@v1",
      rollback: "syrus.coworker_environment/rollback@v1",
      revoke: "syrus.coworker_environment/revoke@v1",
      reset: "syrus.coworker_environment/reset@v1",
      terminate_executions: "syrus.coworker_environment/terminate_executions@v1"
    }.freeze
    NORMAL_OPERATIONS = %i[request_build publish rollback].freeze
    REPAIR_OPERATIONS = %i[revoke reset terminate_executions].freeze
    ROLES = [ AgentRole::CHAT_PLANNER, AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].freeze

    EFFECTS = {
      request_build: %i[isolated_execution internal_write],
      publish: %i[internal_write operational],
      rollback: %i[internal_write operational],
      revoke: %i[internal_write operational destructive],
      reset: %i[internal_write operational destructive],
      terminate_executions: %i[operational destructive]
    }.freeze
    RISKS = {
      request_build: :medium, publish: :high, rollback: :medium,
      revoke: :high, reset: :high, terminate_executions: :critical
    }.freeze

    class << self
      def operation(name) = OPERATIONS.fetch(name.to_sym)

      # This is an availability ceiling, not an authorization decision. A
      # permission rule can narrow an enabled operation but can never make an
      # ordinary environment operation available while the feature is off.
      def feature_gate_allows?(name, subject:)
        name = name.to_sym
        return true if Feature.coworker_custom_environments_enabled?

        REPAIR_OPERATIONS.include?(name) && subject.administrator_repair
      end

      def normalize(subject)
        arguments(subject).sort.to_h
      end

      def redact(subject)
        normalize(subject).merge(
          "reason" => ("[REDACTED REASON]" if arguments(subject)["reason"].present?)
        ).compact
      end

      private

      def arguments(subject)
        value = subject.respond_to?(:permission_arguments) ? subject.permission_arguments : subject.to_h.stringify_keys
        value.slice(*Coworkers::EnvironmentPermissionSubject.members.map(&:to_s))
      end
    end

    OPERATIONS.each do |name, operation|
      effects = EFFECTS.fetch(name)
      risk = RISKS.fetch(name)
      register_capability(
        capability: CAPABILITY, operation:,
        presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
        effects:, risk:, requestable_roles: ROLES, defaults: ROLES.index_with { :ask },
        maximum_autonomy: :invocation, authority_durations: %i[invocation],
        breadth_ceilings: %i[family tool resource].index_with { :invocation },
        resource_scope: { type: :none },
        classifier: ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
        fingerprint_normalizer: method(:normalize), redactor: method(:redact),
        budget_dimensions: (name == :request_build ? %i[compute_time storage network_egress] : [])
      )
    end
  end
end
