module AttentionItems
  # Runs one of an AttentionItem's own typed actions -- entries already
  # validated at save time against the `PendingActions` registry
  # (`AttentionItem#actions_are_known_pending_actions`) -- for an admin
  # operator working the queue outside chat.
  #
  # Mirrors what `ChatPendingAction#execute_confirmation!` does for a chat
  # proposal (validate payload, snapshot a repair action before/after,
  # execute, audit) without a `ChatPendingAction` row, since this queue's
  # actions are opened by backend producers (`AttentionItems::Escalator`,
  # `AttentionItems::Triage`), not proposed in a chat turn.
  class ActionExecutor
    Result = Data.define(:success, :error, :record) do
      def success? = success
    end

    class SimpleErrors
      def initialize
        @messages = []
      end

      def add(attribute, message)
        @messages << "#{attribute} #{message}"
      end

      def any?
        @messages.any?
      end

      def full_messages
        @messages
      end
    end
    private_constant :SimpleErrors

    def self.call(...) = new(...).call

    def initialize(attention_item:, action_key:, user:, reason: nil)
      @attention_item = attention_item
      @action_key = action_key.to_s
      @user = user
      @reason = reason
    end

    def call
      action_hash = action_entry
      return failure("#{@action_key.inspect} is not one of this item's actions") unless action_hash

      command = build_command(action_hash)

      errors = SimpleErrors.new
      command.validate_payload(errors)
      return failure(errors.full_messages.join(", ")) if errors.any?

      repair_targets = command.repair_action? ? Array(command.repair_snapshot_targets).compact : []
      before_snapshot = repair_targets.any? ? PendingActions::RepairAuditSnapshot.capture(repair_targets) : nil

      record = command.execute

      after_snapshot = repair_targets.any? ? PendingActions::RepairAuditSnapshot.capture(repair_targets) : nil

      audit!(action_hash, record, before_snapshot, after_snapshot)

      Result.new(success: true, error: nil, record: record)
    rescue PendingActions::UnknownAction
      failure("unknown pending action #{@action_key.inspect}")
    rescue StandardError => e
      failure("#{e.class}: #{e.message}")
    end

    private

    def build_command(action_hash)
      context = ActionContext.new(
        id: @attention_item.id,
        payload: action_hash["payload"] || {},
        reason: @reason,
        user: AdminActingUser.new(@user),
        repository: @attention_item.repository
      )
      PendingActions.for(@action_key).new(context)
    end

    def action_entry
      Array(@attention_item.actions).find { |action| action.is_a?(Hash) && action["action_key"] == @action_key }
    end

    def audit!(action_hash, record, before_snapshot, after_snapshot)
      AdminAction.log!(
        user: @user,
        action: "attention_item_#{@action_key}",
        params: {
          attention_item_id: @attention_item.id,
          action_key: @action_key,
          label: action_hash["label"],
          reason: @reason,
          payload: action_hash["payload"] || {},
          result: record ? { type: record.class.name, id: record.id } : nil,
          before_snapshot: before_snapshot,
          after_snapshot: after_snapshot
        }.compact
      )
    end

    def failure(message)
      Result.new(success: false, error: message, record: nil)
    end
  end
end
