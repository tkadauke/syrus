module JobCodingMode
  class CancelTakeover
    Error = Class.new(StandardError)

    Result = Data.define(:job, :chat_session)

    def self.call(chat_session:, repository:)
      new(chat_session: chat_session, repository: repository).call
    end

    def initialize(chat_session:, repository:)
      @chat_session = chat_session
      @repository = repository
    end

    def call
      raise Error, "Coding Mode is not enabled on this instance." unless Feature.coding_mode_enabled?
      raise Error, "No active coding checkout for this chat." if @chat_session.coding_checkout_branch.blank?

      job = Job.where(linked_chat_id: @chat_session.id, state: "coding", repository: @repository).first

      ChatWorkspace.cancel_coding_checkout!(@chat_session, @repository)
      job&.release_coding_mode_takeover!

      Result.new(job: job&.reload, chat_session: @chat_session.reload)
    end
  end
end
