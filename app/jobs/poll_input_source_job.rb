class PollInputSourceJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(source_id, *) { "poll_input_source:#{source_id}" }

  def perform(source_id, force: false)
    source = InputSource.find_by(id: source_id)
    return unless source
    return unless force || source.polling_enabled?

    source.poll!
  end
end
