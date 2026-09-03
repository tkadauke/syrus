class BackfillTestIdentitiesJob < ApplicationJob
  queue_as :indexing

  limits_concurrency to: 1,
    key: ->(repository_id) { "test_identities:#{repository_id}" },
    duration: 10.minutes,
    on_conflict: :discard

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository

    TestInsights::TestIdentity.ensure_for_repository!(repository)
  end
end
