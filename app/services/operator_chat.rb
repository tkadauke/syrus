module OperatorChat
  class Disabled < StandardError; end
  class DeliveryError < StandardError; end

  CHANNELS = {
    "in_syrus" => "OperatorChat::Channels::InSyrus",
    "telegram" => "OperatorChat::Channels::Telegram"
  }.freeze

  def self.dispatch!(run:, question:, context:)
    repository = run.job.repository
    channel = repository.allow_operator_chat.to_s
    raise Disabled, "operator chat is disabled for #{repository.slug}" if channel == "disabled"

    klass_name = CHANNELS.fetch(channel) { raise DeliveryError, "unknown operator chat channel: #{channel}" }
    workflow = run.workflow
    raise DeliveryError, "run must belong to a Workflow" unless workflow

    record = nil

    OperatorQuestion.transaction do
      record = OperatorQuestion.create!(
        job: run.job,
        workflow: workflow,
        run: run,
        text: question,
        context: context,
        asked_at: Time.current
      )
      record.channel = channel

      klass_name.constantize.deliver!(record)
    end

    record
  end
end
