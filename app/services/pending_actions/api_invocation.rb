module PendingActions
  class ApiInvocation
    include ActiveModel::Model

    CHAT_BOUND_ACTIONS = {
      "complete_implement_step" => "requires a Coding Mode or Local Mode chat session",
      "emergency_land" => "requires a Coding Mode chat session",
      "local_tool_call" => "requires a Local Mode chat session",
      "submit_chat_feedback" => "requires a chat feedback context",
      "submit_coding_changes" => "requires a persisted chat pending action"
    }.freeze

    attr_reader :action_key, :payload, :reason, :repository, :user, :result, :before_snapshot, :after_snapshot

    def initialize(action_key:, payload:, reason:, user:, repository: nil)
      @action_key = action_key.to_s
      @payload = payload.to_h.deep_stringify_keys
      @reason = reason.to_s.strip
      @user = user
      @repository = repository
      @before_snapshot = {}
      @after_snapshot = {}
      @progress = []
      @result = nil
      super({})
    end

    def call
      validate!

      command.authorize_execution!
      capture_before_snapshot!(command)
      update_confirmation_progress!("running", command.execution_label)
      @result = command.execute
      capture_after_snapshot!(command)
      audit_success!(command)
      result
    end

    def validate!
      raise UnknownAction, "unknown pending action: #{action_key}" unless command_class

      errors.add(:reason, "is required") if reason.blank?
      errors.add(:base, unsupported_action_message) if unsupported_action_message
      raise ActiveRecord::RecordInvalid, self if errors.any?

      command.validate_payload(errors)
      raise ActiveRecord::RecordInvalid, self if errors.any?
    end

    def id = nil
    def chat_session = nil
    def new_record? = true

    def update!(attrs)
      @payload = attrs[:payload].to_h.deep_stringify_keys if attrs.key?(:payload)
      true
    end

    def update_confirmation_progress!(status, step)
      @progress << { status: status, step: step, at: Time.current }
      true
    end

    def progress
      @progress.dup
    end

    private

    def command
      @command ||= command_class.new(self)
    end

    def command_class
      @command_class ||= PendingActions.for(action_key)
    rescue UnknownAction
      nil
    end

    def unsupported_action_message
      reason = CHAT_BOUND_ACTIONS[action_key]
      return nil unless reason

      "#{action_key} #{reason} and cannot be invoked through the admin API"
    end

    def capture_before_snapshot!(command)
      return unless command.repair_action?

      update_confirmation_progress!("running", "Capturing before snapshot...")
      @before_snapshot = RepairAuditSnapshot.capture(command.repair_snapshot_targets)
    end

    def capture_after_snapshot!(command)
      return unless command.repair_action?

      update_confirmation_progress!("running", "Capturing after snapshot...")
      @after_snapshot = RepairAuditSnapshot.capture(command.repair_snapshot_targets)
    end

    def audit_success!(command)
      AdminAction.log!(
        user: user,
        action: "pending_action_#{action_key}",
        params: {
          source: "api",
          action: action_key,
          action_detail: command.action_detail,
          reason: reason,
          payload: payload,
          repository_id: repository&.id,
          result: result_payload,
          before_snapshot: before_snapshot,
          after_snapshot: after_snapshot
        }
      )
    end

    def result_payload
      return nil unless result

      {
        type: result.class.name,
        id: result.respond_to?(:id) ? result.id : nil,
        slug: result.respond_to?(:slug) ? result.slug : nil
      }.compact
    end
  end
end
