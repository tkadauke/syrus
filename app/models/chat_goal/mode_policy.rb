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
end
