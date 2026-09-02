class ChatGoal::ModePolicy
  MODES = {
    "planning" => "ChatGoal::ModePolicy::Planning",
    "coding" => "ChatGoal::ModePolicy::Coding",
    "local" => "ChatGoal::ModePolicy::Local"
  }.freeze

  def self.for(mode)
    constant_name = MODES.fetch(mode.to_s.presence || "planning", "ChatGoal::ModePolicy::Planning")
    constant_name.constantize.new
  end

  def validate(goal)
    raise NotImplementedError
  end

  def auto_submit_coding_handoff?(_goal)
    false
  end

  def requires_ready_coding_checkout_for_continuation?(_goal)
    false
  end
end
