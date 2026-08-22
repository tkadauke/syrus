module WorkUnits
  GateResult = Data.define(:blocked, :reason, :retry_at, :details) do
    def self.pass = new(blocked: false, reason: nil, retry_at: nil, details: {})
    def self.block(reason:, retry_at: nil, details: {}) = new(blocked: true, reason: reason, retry_at: retry_at, details: details || {})

    def blocked? = blocked
    def pass? = !blocked
  end
end
