module Coworkers
  class AfterRunPolicy
    def self.for(name)
      { "quiet" => Quiet, "wake" => Wake }.fetch(name.to_s).new
    rescue KeyError
      raise ArgumentError, "unknown coworker after-run policy"
    end

    class Quiet < AfterRunPolicy
      def enqueue!(**) = false
    end

    class Wake < AfterRunPolicy
      def enqueue!(chat:, task:, source_run:, summary:, duration:)
        queued = false
        ApplicationRecord.transaction do
          claimed = Run.where(id: source_run.id, coworker_wake_enqueued_at: nil)
            .update_all(coworker_wake_enqueued_at: Time.current, updated_at: Time.current)
          next unless claimed == 1

          prompt = Coworkers::Prompts::ScheduledRunFollowup.new(
            task:, run: source_run, summary:, duration_seconds: duration
          ).to_s
          chat.chat_queued_messages.create!(
            content: {
              ChatQueuedMessage::INTERNAL_ROLE_KEY => "system",
              "text" => "Your scheduled run \"#{task.name}\" finished. Follow up with your owner.",
              "source" => "coworker_scheduled_run_followup",
              "background_run_id" => source_run.id,
              "internal_prompt" => prompt
            }
          )
          queued = true
        end
        ChatQueuedMessagePromoter.deliver_one_if_idle!(chat) if queued
        queued
      end
    end
  end
end
