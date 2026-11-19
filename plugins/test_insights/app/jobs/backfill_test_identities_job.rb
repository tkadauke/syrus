class BackfillTestIdentitiesJob < PluginJob
  plugin :test_insights

  def perform(repository_id)
    repository = Repository.find_by(id: repository_id)
    return unless repository

    TestInsights::TestIdentity.ensure_for_repository!(repository)
  end
end
