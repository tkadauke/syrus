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
    record = nil

    OperatorQuestion.transaction do
      record = OperatorQuestion.create!(
        repository: repository,
        job: run.job,
        run: run,
        channel: channel,
        question: question,
        context: context,
        sent_at: Time.current
      )

      klass_name.constantize.deliver!(record)
    end

    record
  end
end
