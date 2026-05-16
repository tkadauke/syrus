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

        repository = chat_session.user.repositories.find_by("LOWER(owner) = ? AND LOWER(name) = ?", owner.downcase, name.downcase)
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
