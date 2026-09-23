# Resolves the preferred git transport for cloning/fetching a repository's
# workspace: the first enabled `:workspace_git_transport` plugin provider
# that says it can serve the repository right now, or nil to use the hosting
# platform directly. See Syrus::Plugin::WorkspaceGitTransport.
module WorkspaceGitTransports
  module_function

  def for(repository, user:)
    return nil unless repository

    Syrus::PluginRegistry.providers_for(:workspace_git_transport).each do |provider_class|
      next unless safe_available_for?(provider_class, repository)

      instance = provider_class.build(repository: repository, user: user)
      return instance if instance
    rescue StandardError => e
      Rails.logger.warn("[WorkspaceGitTransports] #{provider_class} failed to build for #{repository.slug}: #{e.class}: #{e.message}")
    end

    nil
  end

  def safe_available_for?(provider_class, repository)
    provider_class.available_for?(repository)
  rescue StandardError => e
    Rails.logger.warn("[WorkspaceGitTransports] #{provider_class}.available_for? failed for #{repository.slug}: #{e.class}: #{e.message}")
    false
  end
end
