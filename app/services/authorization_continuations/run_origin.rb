module AuthorizationContinuations
  class RunOrigin < Origin
    def self.accepts?(origin) = origin.is_a?(Run)

    def resumable?
      origin.running? && origin.step&.running? && origin.workflow&.running?
    end

    def deliver!(payload)
      origin.update!(
        prompt: Prompts::AuthorizationContinuation.new(payload).to_s,
        parent_session_id: Steps::Base::DISABLE_AGENT_RESUME
      )
    end

    def dispatch!
      RunJob.set(
        queue: RunQueueResolver.resolve(run: origin).queue_name,
        priority: origin.solid_queue_priority
      ).perform_later(origin.id)
    end

    # RunJob claims the resuming checkpoint immediately before invoking the
    # provider. Leaving it in `resuming` until then makes duplicate queue
    # deliveries distinguishable from the one continuation delivery.
    def complete_on_delivery? = false
  end
end
