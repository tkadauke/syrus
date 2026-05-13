require "mcp"

module SyrusChatMcp
  class RepoInfoTool < MCP::Tool
    tool_name "repo_info"

    description "Read repository metadata, recent default-branch commits, and remote branch HEAD shas."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        repository = chat_session.repository
        client = GithubClient.for(repository: repository, user: chat_session.user)
        info = client.repo_info(repository.slug, default_branch: repository.default_branch)

        SyrusChatMcp.success(
          repository: {
            id: repository.id,
            slug: repository.slug,
            default_branch: info.fetch(:default_branch),
            trigger_label: repository.trigger_label,
            agent_provider: repository.effective_agent_provider,
            recent_commits: info.fetch(:recent_commits),
            branches: info.fetch(:branches)
          }
        )
      rescue ArgumentError, Octokit::Error => e
        SyrusChatMcp.invalid(e.message)
      end
    end
  end
end
