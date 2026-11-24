module SourceControl
  class GithubOperations
    include Syrus::Host::SourceControlProvider

    def self.provider_key = "github"

    def self.display_name = "GitHub"

    def self.available_for?(repository)
      repository.present? && repository.slug.to_s.include?("/")
    end

    def self.client_for(repository:, user: nil)
      GithubClient.for(repository: repository, user: user)
    end
  end
end
