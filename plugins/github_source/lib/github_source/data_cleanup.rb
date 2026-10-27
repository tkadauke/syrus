module GithubSource
  module DataCleanup
    def self.install_into(scope)
      scope.effect("repository issue cache") do
        Syrus::DataCleanup.register("Repository", "github_source.github_issues") do |repository|
          Issue.where(repository_id: repository.id).delete_all
        end
      end
    end
  end
end
