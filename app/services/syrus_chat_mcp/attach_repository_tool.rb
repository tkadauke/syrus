require "mcp"

module SyrusChatMcp
  class AttachRepositoryTool < MCP::Tool
    tool_name "attach_repository"

    description "Attach a repository by owner/name slug and clone or fast-forward it into this chat session's workspace."

    input_schema(
      properties: {
        slug: { type: "string", description: "Repository slug, for example tkadauke/syrus." }
      },
      required: %w[slug]
    )

    class << self
      def call(slug:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        owner, name = normalize_slug(slug)
        return SyrusChatMcp.invalid("slug must be owner/name") unless owner && name

        # Attachment is user-gated here: the slug must resolve inside the
        # current user's active repositories before ChatWorkspace can clone it.
        repository = chat_session.user.repositories.active.find_by("LOWER(owner) = ? AND LOWER(name) = ?", owner.downcase, name.downcase)
        return SyrusChatMcp.invalid("repository #{owner}/#{name} is not configured for this user") unless repository

        path = ChatWorkspace.attach_repository!(chat_session, repository)

        SyrusChatMcp.success(
          repository: {
            id: repository.id,
            slug: repository.slug,
            default_branch: repository.default_branch
          },
          workspace_path: ChatWorkspace.path_for(chat_session).to_s,
          repository_path: path.to_s
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      rescue GitRunner::GitError => e
        SyrusChatMcp.invalid(e.message)
      rescue ArgumentError => e
        # GithubClient.for raises ArgumentError when neither an active GitHub
        # App installation nor a usable PAT is available for the repository.
        # Surface that as a usable message instead of an opaque -32603.
        SyrusChatMcp.invalid("could not authenticate to #{slug} for cloning: #{e.message}. Check the repository's GitHub App installation or your GitHub token in credentials.")
      rescue StandardError => e
        # Backstop: any other failure (token exchange, filesystem, etc.) should
        # reach the agent as a tool error, not crash the MCP call (-32603).
        Rails.logger.warn("[SyrusChatMcp] attach_repository failed for #{slug}: #{e.class}: #{e.message}")
        SyrusChatMcp.invalid("failed to attach #{slug}: #{e.message}")
      end

      private

      def normalize_slug(slug)
        parts = slug.to_s.strip.split("/", 2)
        return unless parts.length == 2
        return if parts.any?(&:blank?)

        parts
      end
    end
  end
end
