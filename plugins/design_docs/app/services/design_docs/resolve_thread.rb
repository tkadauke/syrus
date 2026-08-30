module DesignDocs
  class ResolveThread
    Result = Data.define(:thread)

    def self.call(...)
      new(...).call
    end

    def initialize(thread:, user:)
      @thread = thread
      @user = user
    end

    def call
      raise Pundit::NotAuthorizedError unless DesignDocPolicy.new(user, thread.design_doc).review?

      thread.update!(state: "resolved", resolved_at: Time.current, resolved_by_user: user)
      Result.new(thread: thread)
    end

    private

    attr_reader :thread, :user
  end
end
