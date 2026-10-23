class JobCancellationEligibility
  Result = Data.define(:eligible, :message) do
    def eligible? = eligible
  end

  INELIGIBLE_STATES = %w[closed].freeze
  ELIGIBLE_STATES = (Job.aasm.states.map { |state| state.name.to_s } - INELIGIBLE_STATES).freeze

  def self.call(job:)
    return Result.new(eligible: true, message: nil) if ELIGIBLE_STATES.include?(job.state)

    Result.new(
      eligible: false,
      message: "#{job.slug} is already closed. Reopen it first if more work is required."
    )
  end
end
