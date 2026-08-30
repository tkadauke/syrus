class ChatGoalCommand
  Result = Data.define(:handled, :message, :goal)

  PATTERN = /\A\s*\/goal(?:\s+(?<action>pause|resume|stop|edit))?(?:\s+(?<args>.*))?\z/im

  def self.parse(text)
    match = text.to_s.match(PATTERN)
    return unless match

    {
      action: match[:action].presence || "start",
      args: match[:args].to_s.strip
    }
  end

  def initialize(chat_session:, user:)
    @chat_session = chat_session
    @user = user
  end

  def call(text)
    parsed = self.class.parse(text)
    return Result.new(handled: false, message: nil, goal: nil) unless parsed

    goal = nil
    message = nil
    publish_start = false
    @chat_session.with_lock do
      goal = @chat_session.active_goal
      case parsed.fetch(:action)
      when "start"
        prompt = parsed.fetch(:args)
        raise ArgumentError, "Usage: /goal <objective>" if prompt.blank?

        goal = if goal
          was_paused = goal.paused?
          goal.update!(prompt: prompt)
          if goal.paused?
            goal.resume!
            publish_start = was_paused
          end
          goal
        else
          publish_start = true
          @chat_session.chat_goals.create!(user: @user, prompt: prompt)
        end
        message = "Goal updated."
      when "pause"
        require_goal!(goal)
        goal.pause!
        message = "Goal paused."
      when "resume"
        require_goal!(goal)
        goal.resume!
        ChatGoalWakeup.publish_control!(goal, action: "resume")
        message = "Goal resumed."
      when "stop"
        require_goal!(goal)
        goal.stop!(reason: "operator_stopped")
        message = "Goal stopped."
      when "edit"
        require_goal!(goal)
        prompt = parsed.fetch(:args)
        raise ArgumentError, "Usage: /goal edit <objective>" if prompt.blank?

        goal.update!(prompt: prompt)
        message = "Goal updated."
      end
    end

    ChatGoalWakeup.publish_start!(goal) if publish_start

    Result.new(handled: true, message: message, goal: goal&.reload)
  end

  private

  def require_goal!(goal)
    raise ActiveRecord::RecordNotFound, "Active goal was not found." unless goal
  end
end
