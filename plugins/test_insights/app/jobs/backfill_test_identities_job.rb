class BackfillTestIdentitiesJob < Syrus::Host::PluginJob
  plugin :test_insights

  def perform(repository_id)
    repository = Syrus::Host::RepositoryRecord.find_by(id: repository_id)
    return unless repository

    TestInsights::TestIdentity.ensure_for_repository!(repository)
  end
end
