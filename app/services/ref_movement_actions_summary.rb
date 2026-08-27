# Shared name/enabled/mode/grade_phases/available/blocked_reason summary for
# a repository's configured `delivery.ref_movement_actions`, extracted so
# `Mcp::Tools::ListRefMovementActionsTool` and the repository detail API
# payload don't duplicate the same mapping over
# `RefMovementActions::Base.for(name).available?`.
class RefMovementActionsSummary
  def self.for(repository:, job: nil)
    policy = DeliveryPolicy.for(repository: repository)

    policy.ref_movement_actions.map do |name, config|
      available, reason = RefMovementActions::Base.for(name).available?(repository: repository, job: job)
      {
        name: name,
        enabled: config.enabled,
        mode: config.mode,
        grade_phases: config.grade_phases,
        available: config.enabled && available,
        blocked_reason: config.enabled ? (available ? nil : reason) : "not enabled in delivery.ref_movement_actions"
      }
    end
  end
end
