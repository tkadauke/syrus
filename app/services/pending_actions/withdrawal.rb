module PendingActions
  class Withdrawal
    Result = Data.define(:action, :prior_state, :resulting_state, :changed) do
      def to_h
        {
          pending_action_id: action.id,
          action: action.action.presence || action.action_type,
          prior_state: prior_state,
          resulting_state: resulting_state,
          changed: changed
        }
      end
    end

    class NotWithdrawable < StandardError; end
    class GroupedAction < StandardError; end

    def initialize(action, user:, reason: nil)
      @action = action
      @user = user
      @reason = reason.to_s.strip.presence
    end

    def call
      action.with_lock do
        raise ActiveRecord::RecordNotFound, "pending action belongs to another user" if action.user != user
        if action.pending_action_group_id?
          raise GroupedAction,
            "pending action belongs to group #{action.pending_action_group_id}; reject the whole group from its confirmation card"
        end

        prior_state = action.state
        return result(prior_state, changed: false) if action.rejected? || action.cancelled?

        changed = withdraw_active_action!
        raise NotWithdrawable, "pending action cannot be withdrawn from state #{prior_state}" unless changed

        result(prior_state, changed: true)
      end
    end

    private

    attr_reader :action, :user, :reason

    def withdraw_active_action!
      action.update!(reason: reason) if reason
      return action.reject!(user: user) if action.pending? && action.action_type != "schedule_recurring"

      action.cancel!(user: user)
    end

    def result(prior_state, changed:)
      Result.new(
        action: action,
        prior_state: prior_state,
        resulting_state: action.state,
        changed: changed
      )
    end
  end
end
