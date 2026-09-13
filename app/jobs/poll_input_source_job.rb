class PollInputSourceJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  limits_concurrency to: 1, key: ->(source_id, *) { "poll_input_source:#{source_id}" }

  def perform(source_id, force: false)
    source = InputSource.find_by(id: source_id)
    return unless source
    return unless force || source.polling_enabled?
    return unless force || source.provider_enabled?

    source.poll!
  rescue Regexp::TimeoutError => e
    Rails.logger.error(
      "[PollInputSourceJob] regexp timeout source_id=#{source_id} " \
      "source_type=#{source&.type || 'unknown'} " \
      "repository=#{source&.repository&.slug || 'unknown'}: #{e.message}"
    )
    raise
  end
end
