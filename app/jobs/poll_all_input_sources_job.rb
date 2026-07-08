class PollAllInputSourcesJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  def perform
    return if AppSetting.polling_paused?

    InputSource
      .where(polling_enabled: true)
      .joins(:repository)
      .merge(Repository.active)
      .find_each { |source| PollInputSourceJob.perform_later(source.id) }
  end
end
