class LinearIngestPolicy
  Result = Data.define(:allow, :reason)

  def self.evaluate(issue)
    new(issue).evaluate
  end

  def initialize(issue)
    @issue = issue
  end

  def evaluate
    state_type = @issue.dig("state", "type").to_s
    return deny("state is cancelled") if state_type == "cancelled"
    return deny("state is completed") if state_type == "completed"

    allow
  end

  private

  def allow
    Result.new(allow: true, reason: nil)
  end

  def deny(reason)
    Result.new(allow: false, reason: reason)
  end
end
