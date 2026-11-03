module Permissions
  # Stable capability contracts for core chat tools whose effects persist or
  # leave the conversation: scheduled wakeups (persistent autonomy), outbound
  # messages and chat spawning (communication), repository documents
  # (document mutation and deletion), and artifacts a run owns.
  #
  # The mapping only supplies the evaluator with classification, default
  # policy, and fingerprint data. Specialized execution stays where it is:
  # repository-document create/delete keep their pending-action lifecycle and
  # re-validate the live record when the approved action runs, and bridge
  # threads keep their hop limits.
  #
  # Each operation declares how much authority may ever cover it. Safe edits
  # to artifacts the caller owns (+submit_artifact+, +cancel_wakeup+) default
  # to +allow+ because they only touch the caller's own recoverable state.
  # Everything that schedules future autonomy, contacts another chat, or
  # deletes a document defaults to +ask+. Document deletion is capped at
  # exact-invocation authority.
  class EffectActions
    Operation = Data.define(:capability, :name, :effects, :risk, :default, :maximum_autonomy, :durations)

    SCHEDULES = "syrus.schedules@v1".freeze
    COMMUNICATION = "syrus.communication@v1".freeze
    DOCUMENTS = "syrus.documents@v1".freeze
    ARTIFACTS = "syrus.artifacts@v1".freeze

    INVOCATION = %i[invocation].freeze
    SESSION = %i[invocation chat_session].freeze
    JOB = %i[invocation chat_session job].freeze

    OPERATIONS = {
      "schedule_wakeup" => Operation.new(SCHEDULES, "schedule_wakeup", %i[internal_write persistent_autonomy], :medium, :ask, :chat_session, SESSION),
      "cancel_wakeup" => Operation.new(SCHEDULES, "cancel_wakeup", %i[internal_write], :low, :allow, :permanent, CapabilityDescriptor::AUTHORITY_DURATIONS),
      "send_chat_message" => Operation.new(COMMUNICATION, "send_chat_message", %i[internal_write communication], :medium, :ask, :chat_session, SESSION),
      "spawn_chats" => Operation.new(COMMUNICATION, "spawn_chats", %i[internal_write communication persistent_autonomy], :high, :ask, :invocation, INVOCATION),
      "create_repo_document" => Operation.new(DOCUMENTS, "create", %i[internal_write], :medium, :ask, :job, JOB),
      "delete_repo_document" => Operation.new(DOCUMENTS, "delete", %i[internal_write destructive], :high, :ask, :invocation, INVOCATION),
      "submit_artifact" => Operation.new(ARTIFACTS, "submit", %i[internal_write], :low, :allow, :permanent, CapabilityDescriptor::AUTHORITY_DURATIONS)
    }.freeze

    class << self
      def tool_names = OPERATIONS.keys

      def covers?(tool_name) = OPERATIONS.key?(tool_name.to_s)

      def descriptor_for(tool_name, required_roles: AgentRole::CHAT_ROLES)
        operation = OPERATIONS.fetch(tool_name.to_s)
        identifier = "#{operation.capability.delete_suffix('@v1')}/#{operation.name}@v1"
        roles = Array(required_roles)

        CapabilityDescriptor.new(
          capability: operation.capability,
          operation: identifier,
          effects: operation.effects,
          risk: operation.risk,
          requestable_roles: roles,
          defaults: roles.index_with { operation.default },
          maximum_autonomy: operation.maximum_autonomy,
          authority_durations: operation.durations,
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation: identifier, effects: operation.effects, risk: operation.risk, confidence: :certain } },
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:normalize_arguments)
        )
      end

      # Exact arguments, key-sorted, with blank optional values dropped so an
      # omitted argument and an explicit nil fingerprint identically.
      def normalize_arguments(arguments)
        arguments.to_h.transform_keys(&:to_s).reject { |_key, value| value.nil? }.sort_by { |key, _| key }.to_h
      end
    end
  end
end
