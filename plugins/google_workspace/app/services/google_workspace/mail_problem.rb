module GoogleWorkspace
  class MailProblem < StandardError
    attr_reader :code, :retry_after

    def initialize(code:, message:, retry_after: nil)
      @code = code.to_s
      @retry_after = retry_after
      super(message)
    end
  end
end
