module Permissions
  # Explicit capability contracts for the remaining state-changing core chat
  # tools. These operations intentionally keep the legacy authorization
  # ceiling: every mutation is authorized for one exact invocation only.
  class ChatMutationActions
    Operation = Data.define(:capability, :name, :effects, :risk, :default)

    INTERNAL = %i[internal_write].freeze
    WORK_CONTROL = %i[internal_write operational].freeze
    DESTRUCTIVE = %i[internal_write destructive].freeze
    EXECUTION = %i[internal_write isolated_execution].freeze
    RUNTIME_CONTROL = %i[internal_write isolated_execution operational].freeze

    def self.operation(capability, name, effects = INTERNAL, risk = :medium, default = :ask)
      Operation.new("syrus.#{capability}@v1", name, effects, risk, default)
    end
    private_class_method :operation

    OPERATIONS = {
      "propose_epic" => operation("proposals", "propose_epic"),
      "propose_job" => operation("proposals", "propose_job"),
      "propose_epic_with_jobs" => operation("proposals", "propose_epic_with_jobs"),
      # Withdrawing the agent's own undecided draft is the inverse of drafting
      # it: essential, not destructive (the proposal is only marked withdrawn).
      "delete_proposal" => operation("proposals", "delete", INTERNAL, :low),
      "withdraw_pending_action" => operation("pending_actions", "withdraw", INTERNAL, :low, :allow),
      "set_bookmark" => operation("chat_context", "set_bookmark", INTERNAL, :low, :allow),
      "override_job_planned_execution" => operation("jobs", "override_planned_execution", WORK_CONTROL),
      "mutate_provider_routing_rules" => operation("provider_routing", "mutate_rules", WORK_CONTROL, :high),
      "set_job_priority" => operation("jobs", "set_priority"),
      "rename_chat" => operation("chats", "rename", INTERNAL, :low, :allow),
      "pin_chat" => operation("chats", "pin", INTERNAL, :low, :allow),
      "unpin_chat" => operation("chats", "unpin", INTERNAL, :low, :allow),
      "suggest_next_step" => operation("chat_goals", "suggest_next_step", INTERNAL, :low, :allow),
      "ask_user_question" => operation("chat_goals", "ask_user_question", INTERNAL, :low, :allow),
      "mark_goal_completed" => operation("chat_goals", "complete", INTERNAL, :low, :allow),
      "mark_goal_blocked" => operation("chat_goals", "block", INTERNAL, :low, :allow),
      "reset_workspace" => operation("coding_workspace", "reset", DESTRUCTIVE, :high),
      "cancel_coding_checkout" => operation("coding_workspace", "cancel_checkout", DESTRUCTIVE, :high),
      "complete_implement_step" => operation("coding_workspace", "complete_implement", WORK_CONTROL, :high),
      "open_in_coding_mode" => operation("coding_workspace", "open", WORK_CONTROL, :high),
      "submit_coding_changes" => operation("coding_workspace", "submit", WORK_CONTROL, :high),
      "runtime_start" => operation("runtime", "start", RUNTIME_CONTROL, :high),
      "runtime_build_or_reload" => operation("runtime", "build_or_reload", RUNTIME_CONTROL, :high),
      "runtime_launch" => operation("runtime", "launch", RUNTIME_CONTROL, :high),
      "runtime_snapshot" => operation("runtime", "snapshot", EXECUTION),
      "runtime_acquire_control" => operation("runtime", "acquire_control", RUNTIME_CONTROL, :high),
      "runtime_release_control" => operation("runtime", "release_control", INTERNAL, :low),
      "runtime_input" => operation("runtime", "input", RUNTIME_CONTROL, :high),
      "runtime_capture_artifact" => operation("runtime", "capture_artifact", EXECUTION),
      "runtime_stop" => operation("runtime", "stop", RUNTIME_CONTROL, :high),
      "open_in_local_mode" => operation("local_mode", "open", WORK_CONTROL, :high),
      "cancel_local_mode" => operation("local_mode", "cancel", DESTRUCTIVE, :high),
      "update_pinned_context" => operation("chat_context", "update_pinned", INTERNAL, :low, :allow),
      "remove_pinned_context" => operation("chat_context", "remove_pinned", INTERNAL, :low, :allow),
      "update_job" => operation("jobs", "update"),
      "assign_job_to_epic" => operation("jobs", "assign_to_epic"),
      "create_tag" => operation("tags", "create"),
      "add_job_tag" => operation("tags", "add_to_job"),
      "remove_job_tag" => operation("tags", "remove_from_job"),
      "run_visual_review" => operation("visual_review", "run", WORK_CONTROL),
      "run_visual_diff" => operation("visual_review", "run_diff", WORK_CONTROL),
      "delegate_issue" => operation("github_issues", "delegate", %i[credential_use external_write operational], :high),
      "remove_job_from_epic" => operation("jobs", "remove_from_epic"),
      "update_epic" => operation("epics", "update"),
      "add_epic_dependency" => operation("epics", "add_dependency"),
      "remove_epic_dependency" => operation("epics", "remove_dependency"),
      "add_job_dependency" => operation("jobs", "add_dependency"),
      "remove_job_dependency" => operation("jobs", "remove_dependency"),
      "replace_job_dependency" => operation("jobs", "replace_dependency")
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
          presentation: CapabilityPresentation.for(capability: operation.capability, operation: identifier),
          effects: operation.effects,
          risk: operation.risk,
          requestable_roles: roles,
          defaults: roles.index_with { operation.default },
          maximum_autonomy: :invocation,
          authority_durations: %i[invocation],
          resource_scope: { type: :none },
          classifier: ->(_arguments) do
            { operation: identifier, effects: operation.effects, risk: operation.risk, confidence: :certain }
          end,
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:redact_arguments)
        )
      end

      def normalize_arguments(arguments)
        deep_transform(arguments) { |_key, value| value }
      end

      def redact_arguments(arguments)
        deep_transform(arguments) do |key, value|
          key.to_s.match?(CapabilityDescriptorAdapter::REDACTED_KEYS) ? "[REDACTED]" : value
        end
      end

      private

      def deep_transform(value, key = nil, &block)
        transformed = case value
        when Hash
          value.to_h.sort_by { |item_key, _| item_key.to_s }.to_h do |item_key, item|
            [ item_key.to_s, deep_transform(item, item_key, &block) ]
          end
        when Array then value.map { |item| deep_transform(item, nil, &block) }
        else value
        end
        block.call(key, transformed)
      end
    end
  end
end
