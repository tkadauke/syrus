module ChatChannel
  class Telegram
    def send_message(run:, text:, context: {}, asked_at: Time.current)
      workflow = run.workflow
      raise ArgumentError, "run must belong to a Workflow" unless workflow

      question = nil
      OperatorQuestion.transaction do
        question = OperatorQuestion.create!(
          run: run,
          workflow: workflow,
          job: run.job,
          text: text,
          context: context.presence || {},
          asked_at: asked_at
        )
        OperatorChat::Channels::Telegram.deliver!(question)
      end
      question
    end
  end
end
