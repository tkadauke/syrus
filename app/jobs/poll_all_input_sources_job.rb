class PollAllInputSourcesJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?

    source_ids = InputSource
      .where(polling_enabled: true)
      .joins(:repository)
      .merge(Repository.active)
      .find_each
      .filter_map do |source|
        source.id if source.provider_enabled?
      end

    PollInputSourceJob.perform_later_missing_simple_args(source_ids.map { |id| [ id ] })
  end
end
