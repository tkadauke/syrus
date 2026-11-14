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

    def call
      return false if task.consecutive_failure_count < FAILURE_THRESHOLD

      queued = false
      task.with_lock do
        task.reload
        history = Array(task.system_result_history)
        entry = history.find { |item| item["date"] == date.iso8601 }
        next unless entry && entry["alerted_at"].blank?

        entry["alerted_at"] = Time.current.iso8601
        task.update!(system_result_history: history)
        chat.chat_queued_messages.create!(content: {
          ChatQueuedMessage::INTERNAL_ROLE_KEY => "system",
          "text" => "Journaling is failing for #{date.iso8601}.",
          "source" => SOURCE,
          "journaling_date" => date.iso8601,
          "internal_prompt" => "Tell your owner that journaling is failing for #{date.iso8601}. " \
            "Explain the recorded failure and that Syrus will retry without pausing the system schedule. Failure: #{reason}"
        })
        queued = true
      end
      ChatQueuedMessagePromoter.deliver_one_if_idle!(chat) if queued
      queued
    end

    private

    attr_reader :task, :date, :reason

    def chat
      @chat ||= Coworkers::Coworker.find(task.coworker_id)
        .coworker_chats.find_by!(role: "main").chat_session
    end
  end
end
