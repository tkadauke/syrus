module Mcp::ControlToolContracts
  JOB_STATES = Job.aasm.states.map { |state| state.name.to_s }.freeze
  RETRY_JOB_STATES = (JOB_STATES - %w[approved landing closed]).freeze
  CANCEL_JOB_STATES = (JOB_STATES - %w[closed]).freeze
  CODING_HANDOFF_JOB_STATES = %w[coding].freeze
  TAKEOVER_JOB_STATES = %w[implemented approved].freeze

  def self.states(states)
    states.map { |state| "`#{state}`" }.join(", ")
  end
end
