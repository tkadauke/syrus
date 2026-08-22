module WorkIntents
  GateResult = Data.define(:waiting, :reason, :retry_at, :details) do
    def self.pass = new(waiting: false, reason: nil, retry_at: nil, details: {})
    def self.wait(reason:, retry_at: nil, details: {}) = new(waiting: true, reason: reason, retry_at: retry_at, details: details || {})

    def waiting? = waiting
    def pass? = !waiting
  end
end
