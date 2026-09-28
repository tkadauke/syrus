class CognitiveEngagementBackfillJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform(repository_id = nil)
    scope = repository_id.present? ? Repository.where(id: repository_id) : Repository.all
    scope.find_each do |repository|
      CognitiveEngagementEvents::SourceIngestor.call(repository: repository)
    end
  end
end
