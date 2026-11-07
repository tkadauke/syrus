module RepositoryTabsSerialization
  extend ActiveSupport::Concern

  private

  def repository_tabs_json(repository)
    Repositories::PluginRepoTabsPayload.new(repository: repository, user: Current.user).as_json.fetch(:tabs).map do |tab|
      tab.slice(:key, :label, :path, :badge).compact
    end
  end
end
