module ScheduledTasks
  # Permission contract for the chat tools that create, change, and run
  # persistent automation. A scheduled task keeps launching Jobs after the chat
  # that created it is gone, so every operation that adds or alters that
  # autonomy declares +persistent_autonomy+ and asks by default.
  #
  # - Observation (+list+, +read+) is automatic.
  # - Pausing only removes autonomy, so it is automatic as well.
  # - Creating, editing (the cadence and prompt are what recur), resuming, and
  #   firing a task ask. Creating and editing may be covered for the current
  #   chat session; resuming and firing are bound to the exact invocation.
  # - Deleting is destructive and is bound to the exact invocation.
  #
  # The mapping only supplies classification, default policy, and fingerprint
  # data. Creation and immediate firing keep their pending-action lifecycle, and
  # the approved action re-validates repository write access when it runs.
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = AgentRole::CHAT_ROLES
    OBSERVE = "scheduled_tasks.observe@v1".freeze
    AUTOMATION = "scheduled_tasks.automation@v1".freeze

    INVOCATION = %i[invocation].freeze
    SESSION = %i[invocation chat_session].freeze

    class << self
      # Exact arguments, key-sorted, with omitted optionals dropped so an
      # omitted argument and an explicit nil fingerprint identically.
      def normalize_arguments(arguments)
        arguments.to_h.transform_keys(&:to_s).reject { |_key, value| value.nil? }.sort_by { |key, _| key }.to_h
      end

      def fixed_classifier(operation, effects, risk)
        ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } }
      end

      def define(capability:, name:, effects:, risk:, default:, maximum_autonomy:, durations:)
        operation = "scheduled_tasks/#{name}@v1"
        register_capability(
          capability:, operation:, effects:, risk:,
          requestable_roles: ROLES, defaults: ROLES.index_with { default },
          maximum_autonomy:, authority_durations: durations,
          resource_scope: { type: :none },
          classifier: fixed_classifier(operation, effects, risk),
          fingerprint_normalizer: method(:normalize_arguments), redactor: method(:normalize_arguments)
        )
      end
    end

    define(capability: OBSERVE, name: "list", effects: %i[local_read], risk: :low,
           default: :allow, maximum_autonomy: :permanent, durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS)
    define(capability: OBSERVE, name: "read", effects: %i[local_read], risk: :low,
           default: :allow, maximum_autonomy: :permanent, durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS)
    define(capability: AUTOMATION, name: "pause", effects: %i[internal_write], risk: :low,
           default: :allow, maximum_autonomy: :permanent, durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS)
    define(capability: AUTOMATION, name: "create", effects: %i[internal_write persistent_autonomy], risk: :medium,
           default: :ask, maximum_autonomy: :chat_session, durations: SESSION)
    define(capability: AUTOMATION, name: "update", effects: %i[internal_write persistent_autonomy], risk: :medium,
           default: :ask, maximum_autonomy: :chat_session, durations: SESSION)
    define(capability: AUTOMATION, name: "resume", effects: %i[internal_write persistent_autonomy], risk: :medium,
           default: :ask, maximum_autonomy: :invocation, durations: INVOCATION)
    define(capability: AUTOMATION, name: "fire_now", effects: %i[internal_write persistent_autonomy], risk: :high,
           default: :ask, maximum_autonomy: :invocation, durations: INVOCATION)
    define(capability: AUTOMATION, name: "delete", effects: %i[internal_write destructive], risk: :high,
           default: :ask, maximum_autonomy: :invocation, durations: INVOCATION)
  end
end
