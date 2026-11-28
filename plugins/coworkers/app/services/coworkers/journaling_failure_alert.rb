module Coworkers
  class JournalingFailureAlert
    SOURCE = "coworker_journaling_failure".freeze
    FAILURE_THRESHOLD = 3

    def self.call(...) = new(...).call

    def initialize(task:, date:, reason:)
      @task = task
      @date = date
      @reason = reason
    end

    # Runs inside the scheduled-task failure bookkeeping transaction, so it must
    # not raise for an ordinary state: a coworker without a main chat has
    # nowhere to tell its owner, and raising there rolled back the failure
    # count that keeps the nightly retry budget honest.
    def call
      return false if task.consecutive_failure_count < FAILURE_THRESHOLD
      return false unless chat

      queued = false
      task.with_lock do
        task.reload(lock: true)
        history = Array(task.system_result_history)
        entry = history.find { |item| item["date"] == date.iso8601 }
        next unless entry && entry["alerted_at"].blank?

        entry["alerted_at"] = Time.current.iso8601
        task.update!(system_result_history: history)
        chat.chat_queued_messages.create!(content: {
          Syrus::Host::ChatDelivery.internal_role_key => "system",
          "text" => "Journaling is failing for #{date.iso8601}.",
          "source" => SOURCE,
          "journaling_date" => date.iso8601,
          "internal_prompt" => "Tell your owner that journaling is failing for #{date.iso8601}. " \
            "Explain the recorded failure and that Syrus will retry without pausing the system schedule. Failure: #{reason}"
        })
        queued = true
      end
      Syrus::Host::ChatDelivery.deliver_next_if_idle!(chat) if queued
      queued
    end

    private

    attr_reader :task, :date, :reason

    def chat
      return @chat if defined?(@chat)

      @chat = Coworkers::Coworker.find(task.coworker_id)
        .coworker_chats.find_by(role: "main")&.chat_session
    end
  end
end
