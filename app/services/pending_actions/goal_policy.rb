module PendingActions
  class GoalPolicy
    def self.apply_after_create!(action)
      new(action).apply_after_create!
    end

    def initialize(action)
      @action = action
    end

    def apply_after_create!
      @action.enqueue_confirmation! if auto_confirm?
    end

    private

    def auto_confirm?
      @action.action == "submit_coding_changes" &&
        @action.pending? &&
        active_goal&.auto_submit_coding_handoffs?
    end

    def active_goal
      @active_goal ||= @action.chat_session.active_goal
    end
  end
end
