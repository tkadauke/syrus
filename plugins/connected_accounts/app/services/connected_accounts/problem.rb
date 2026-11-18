module ConnectedAccounts
  class Problem < StandardError
    attr_reader :code, :retry_after

    def initialize(code:, message:, retry_after: nil)
      @code = code.to_s
      @retry_after = retry_after&.to_i
      super(message)
    end

    def as_json(*) = { code: code, message: message, retry_after: retry_after }.compact
  end
end
